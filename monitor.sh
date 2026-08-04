#!/bin/bash

set -euo pipefail

# -----------------------------
# DO NOT SOURCE GUARD
# -----------------------------
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "ERROR: Do not source this script"
  exit 1
fi

DEBUG="${DEBUG:-0}"
debug() { [[ "$DEBUG" == "1" ]] && echo "DEBUG: $*"; }

API_CONF="/etc/illumio-ai-monitor/api.conf"
[[ -f "$API_CONF" ]] || { echo "missing api.conf"; exit 1; }

set +u
source "$API_CONF"
set -u

ACTIVATION_CFG="/opt/illumio_ven_data/etc/agent_activation.cfg"
AGENT_CFG="/opt/illumio_ven_data/etc/agent_id.cfg"

for i in {1..60}; do
    [[ -f "$ACTIVATION_CFG" ]] && [[ -f "$AGENT_CFG" ]] && break
    echo "Waiting for VEN registration..."
    sleep 10
done

PCE_HOST=$(awk -F': ' '/masterconfig_server/ {print $2}' "$ACTIVATION_CFG" | cut -d: -f1)
PCE_PORT=$(awk -F': ' '/masterconfig_server/ {print $2}' "$ACTIVATION_CFG" | cut -d: -f2)

ORG_ID=$(awk -F': ' '/org_id/ {print $2}' "$AGENT_CFG")
WORKLOAD_ID=$(awk -F': ' '/workload_uuid/ {print $2}' "$AGENT_CFG")

PCE_URL="https://${PCE_HOST}:${PCE_PORT}/api/v2/orgs/${ORG_ID}/workloads/${WORKLOAD_ID}"

LOGDIR="/opt/illumio_ven_data/log"
OUTDIR="/opt/illumio-ai-monitor/output"
mkdir -p "$OUTDIR"

# -----------------------------
# OUTPUT CLEANUP
# -----------------------------
ls -1t "$OUTDIR"/20*.log 2>/dev/null | tail -n +101 | xargs -r rm -f || true
ls -1t "$OUTDIR"/model_*.raw.txt 2>/dev/null | tail -n +101 | xargs -r rm -f || true

TS=$(date +%Y%m%d-%H%M%S)
OUTFILE="$OUTDIR/$TS.log"

# -----------------------------
# FILTERED LOG COLLECTION
# -----------------------------
for file in platform.log agentmgr.log event.log; do
  path="$LOGDIR/$file"
  [[ -f "$path" ]] || continue

  echo "===== $file =====" >> "$OUTFILE"

  FILTERED=$(tail -n 50 "$path" | grep -iE "error|fail|warn" || true)

  if [[ -n "$FILTERED" ]]; then
    echo "$FILTERED" | sed -E 's/<[^>]+>//g' >> "$OUTFILE"
  else
    tail -n 10 "$path" | sed -E 's/<[^>]+>//g' >> "$OUTFILE"
  fi
done

[[ -s "$OUTFILE" ]] || exit 0

# -----------------------------
# CHECKSUM SKIP
# -----------------------------
CHECKSUM_FILE="$OUTDIR/last.checksum"
CURRENT_SUM=$(sha256sum "$OUTFILE" | awk '{print $1}')

if [[ -f "$CHECKSUM_FILE" ]]; then
  if [[ "$(cat "$CHECKSUM_FILE")" == "$CURRENT_SUM" ]]; then
    debug "No changes, skipping AI"
    exit 0
  fi
fi

echo "$CURRENT_SUM" > "$CHECKSUM_FILE"

# -----------------------------
# AI INPUT
# -----------------------------
AI_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
RAW_INPUT=$(mktemp)
RAW_MODEL="$OUTDIR/latest.raw.txt"
JSON_FILE="$OUTDIR/latest.json"

printf '%s\n' \
'You are a strict JSON log analysis engine.' \
'' \
'YOU MUST ONLY RETURN valid JSON.' \
'No markdown.' \
'No code fences.' \
'No explanations.' \
'Output must start with { and end with }.' \
'' \
'OUTPUT FORMAT:' \
'{"timestamp":"'"$AI_TS"'","severity":"low","confidence":0.0,"issue":"","recommendation":""}' \
'' \
'Severity MUST be exactly one of: low, medium, high, critical.' \
'' \
'SEVERITY RULES:' \
'- critical = confirmed compromise or active attack' \
'- high = enforcement failure or major service impact' \
'- medium = repeated operational failures' \
'- low = isolated issue, warning, or normal operation' \
'' \
'LOG INTERPRETATION RULES:' \
'- ERROR indicates a problem' \
'- WARN indicates a potential issue' \
'- FAIL indicates failure' \
'- INFO is normal operation' \
'- PASS indicates success' \
'- Recovery messages reduce severity when appropriate' \
'' \
'STRICT OUTPUT RULES:' \
'- issue must be a short human readable summary' \
'- recommendation must be a short human readable action' \
'- NEVER copy log lines' \
'- NEVER repeat raw ERROR messages' \
'- NEVER include INFO, WARN, ERROR, or FAIL text verbatim' \
'- NEVER include timestamps from logs' \
'- NEVER include stack traces' \
'- NEVER include file paths' \
'- NEVER include multiple sentences in issue' \
'- issue maximum 80 characters' \
'- recommendation maximum 120 characters' \
'- summarize root cause only' \
'' \
'GOOD EXAMPLES:' \
'{"timestamp":"'"$AI_TS"'","severity":"medium","confidence":0.8,"issue":"Firewall policy generation repeatedly failing","recommendation":"Verify VEN connectivity and policy synchronization"}' \
'' \
'{"timestamp":"'"$AI_TS"'","severity":"low","confidence":0.2,"issue":"No actionable issue detected","recommendation":"No action required"}' \
'' \
'If logs show normal operation or successful recovery:' \
'{"timestamp":"'"$AI_TS"'","severity":"low","confidence":0.2,"issue":"No actionable issue detected","recommendation":"No action required"}' \
'' \
'LOGS:' \
> "$RAW_INPUT"

cat "$OUTFILE" >> "$RAW_INPUT"

# -----------------------------
# RUN MODEL
# -----------------------------
export HOME=/root

if ! pgrep -x ollama >/dev/null 2>&1; then
    echo "Starting Ollama..."
    nohup /usr/local/bin/ollama serve >/var/log/ollama.log 2>&1 &
fi

for i in {1..30}; do
    ollama list >/dev/null 2>&1 && break
    echo "Waiting for Ollama..."
    sleep 2
done

if ! ollama list >/dev/null 2>&1; then
    echo "Ollama API unavailable"
    JSON='{"timestamp":"'"$AI_TS"'","severity":"low","confidence":0.2,"issue":"ollama_unavailable","recommendation":"Verify Ollama service"}'
else
    timeout 120 ollama run qwen2.5:1.5b --nowordwrap < "$RAW_INPUT" > "$RAW_MODEL" 2>/dev/null || {
        JSON='{"timestamp":"'"$AI_TS"'","severity":"low","confidence":0.2,"issue":"analysis_failed","recommendation":"Monitor logs"}'
    }
fi

# -----------------------------
# JSON EXTRACTION
# -----------------------------
if [[ -z "${JSON:-}" ]]; then
JSON=$(python3 - "$RAW_MODEL" <<'PY'
import sys
import json
import re

path = sys.argv[1]

try:
    text = open(path, errors="ignore").read()
except Exception:
    print("")
    sys.exit(0)

text = re.sub(r'<think>.*?</think>', '', text, flags=re.S)

decoder = json.JSONDecoder()

for i, ch in enumerate(text):
    if ch != "{":
        continue
    try:
        obj, end = decoder.raw_decode(text[i:])
        if isinstance(obj, dict):
            print(json.dumps(obj, separators=(",", ":")))
            sys.exit(0)
    except Exception:
        continue

print("")
PY
)
fi

if [[ "$DEBUG" == "1" ]]; then
  echo "========== RAW MODEL =========="
  cat "$RAW_MODEL" || true
  echo
  echo "========== JSON VAR =========="
  printf '%s\n' "${JSON:-}"
  echo "==============================="
fi

if [[ -z "${JSON:-}" ]]; then
  JSON='{"timestamp":"'"$AI_TS"'","severity":"low","confidence":0.2,"issue":"analysis_failed","recommendation":"Monitor logs"}'
fi

# -----------------------------
# FORCE JSON TO BE OBJECT
# -----------------------------
if echo "$JSON" | jq -e 'type=="object"' >/dev/null 2>&1; then
  echo "$JSON" > "$JSON_FILE"
else
  CLEAN_JSON=$(echo "$JSON" | sed 's/^"//;s/"$//' | sed 's/\\"/"/g')

  if echo "$CLEAN_JSON" | jq -e 'type=="object"' >/dev/null 2>&1; then
    echo "$CLEAN_JSON" > "$JSON_FILE"
  else
    echo "{\"timestamp\":\"$AI_TS\",\"severity\":\"low\",\"confidence\":0.2,\"issue\":\"analysis_failed\",\"recommendation\":\"Monitor logs\"}" > "$JSON_FILE"
  fi
fi

if ! jq empty "$JSON_FILE" >/dev/null 2>&1; then
  echo "{\"timestamp\":\"$AI_TS\",\"severity\":\"low\",\"confidence\":0.2,\"issue\":\"invalid_json\",\"recommendation\":\"Monitor logs\"}" > "$JSON_FILE"
fi

# -----------------------------
# SAFE PARSE
# -----------------------------
SEVERITY=$(jq -r '.severity // "low"' "$JSON_FILE" | tr '[:upper:]' '[:lower:]')
CONFIDENCE=$(jq -r '.confidence // 0.2' "$JSON_FILE")
ISSUE=$(jq -r '.issue // ""' "$JSON_FILE")
RECOMMENDATION=$(jq -r '.recommendation // ""' "$JSON_FILE")

ISSUE=$(echo "$ISSUE" | sed -E 's/<[^>]+>//g;s/[<>]//g')
RECOMMENDATION=$(echo "$RECOMMENDATION" | sed -E 's/<[^>]+>//g;s/[<>]//g')

ISSUE=$(printf '%s' "$ISSUE" | tr '\n' ' ' | cut -c1-80)
RECOMMENDATION=$(printf '%s' "$RECOMMENDATION" | tr '\n' ' ' | cut -c1-120)

# -----------------------------
# DETERMINISTIC FALLBACKS FROM LOG CONTENT
# -----------------------------
if grep -qi "failed to open" "$OUTFILE"; then
  SEVERITY="medium"
  CONFIDENCE="0.7"
  ISSUE="Firewall rules file missing or inaccessible"
  RECOMMENDATION="Verify file exists and permissions are correct"
fi

if [[ -z "$ISSUE" && $(grep -ci "ERROR" "$OUTFILE") -gt 0 ]]; then
  SEVERITY="medium"
  CONFIDENCE="0.7"
  ISSUE="Error events detected in VEN logs"
  RECOMMENDATION="Review filtered VEN logs and verify agent health"
fi

if [[ -z "$ISSUE" ]]; then
  ISSUE="No actionable issue detected"
  RECOMMENDATION="No action required"
  SEVERITY="low"
  CONFIDENCE="0.2"
fi

if [[ -z "$RECOMMENDATION" ]]; then
  RECOMMENDATION="No action required"
fi

# -----------------------------
# CLASSIFICATION CLEANUP
# -----------------------------
case "$ISSUE" in
  *proc_stopped*proc_started*)
    ISSUE="Routine process restart detected"
    RECOMMENDATION="No action required"
    SEVERITY="low"
    CONFIDENCE="0.2"
    ;;
esac

if [[ "$SEVERITY" != "low" && -z "$ISSUE" ]]; then
  ISSUE="Detected error condition in logs"
fi

if [[ -z "$RECOMMENDATION" ]]; then
  RECOMMENDATION="Review logs and verify system health"
fi

# -----------------------------
# INTELLIGENT COMPACTION
# -----------------------------
MAX_BYTES=250

build_json() {
  jq -n -c \
    --arg ts "$AI_TS" \
    --arg s "$SEVERITY" \
    --arg c "$CONFIDENCE" \
    --arg i "$ISSUE" \
    --arg r "$RECOMMENDATION" \
    '{timestamp:$ts,severity:$s,confidence:($c|tonumber),issue:$i,recommendation:$r}'
}

len() {
  printf '%s' "$1" | wc -c | tr -d ' '
}

trim() {
  printf '%s' "$1" | cut -c1-"$2" | sed 's/[[:space:]]*$//'
}

JSON_OUT=$(build_json)

if [[ $(len "$JSON_OUT") -gt $MAX_BYTES ]]; then
  RECOMMENDATION=$(trim "$RECOMMENDATION" 80)
  JSON_OUT=$(build_json)
fi

if [[ $(len "$JSON_OUT") -gt $MAX_BYTES ]]; then
  ISSUE=$(trim "$ISSUE" 70)
  JSON_OUT=$(build_json)
fi

if [[ $(len "$JSON_OUT") -gt $MAX_BYTES ]]; then
  JSON_OUT=$(jq -n -c \
    --arg s "$SEVERITY" \
    --arg c "$CONFIDENCE" \
    --arg i "$(trim "$ISSUE" 60)" \
    --arg r "$(trim "$RECOMMENDATION" 60)" \
    '{s:$s,c:($c|tonumber),i:$i,r:$r}')
fi

while [[ $(printf '%s' "$JSON_OUT" | wc -c | tr -d ' ') -gt 200 ]]; do
    ISSUE=$(trim "$ISSUE" $((${#ISSUE} - 10)))
    RECOMMENDATION=$(trim "$RECOMMENDATION" $((${#RECOMMENDATION} - 10)))
    JSON_OUT=$(build_json)

    [[ ${#ISSUE} -lt 30 ]] && break
done

EXT_DS="$JSON_OUT"

PAYLOAD=$(jq -n \
  --arg ds "$EXT_DS" \
  '{external_data_set:$ds,external_data_reference:"Raiden Wins!"}')

debug "JSON_OUT bytes: $(printf '%s' "$JSON_OUT" | wc -c | tr -d ' ')"
debug "PAYLOAD bytes: $(printf '%s' "$PAYLOAD" | wc -c | tr -d ' ')"
debug "Payload external_data_set bytes: $(printf '%s' "$EXT_DS" | wc -c | tr -d ' ')"

echo "PUSHING TO PCE..."

if [[ "$DEBUG" == "1" ]]; then
    echo "========== FINAL PAYLOAD =========="
    echo "$PAYLOAD" | jq .
    echo "==================================="
fi

echo "========== AUTH DEBUG =========="
echo "API_KEY length=${#API_KEY}"
echo "API_SECRET length=${#API_SECRET}"
echo "PCE_URL=$PCE_URL"
echo "================================"

HTTP_CODE=$(
curl -sk \
  -o /tmp/illumio-put-response.json \
  -w "%{http_code}" \
  -X PUT \
  -u "${API_KEY}:${API_SECRET}" \
  -H "Content-Type: application/json" \
  "$PCE_URL" \
  -d "$PAYLOAD"
)

echo "HTTP_CODE=$HTTP_CODE"

if [[ "$DEBUG" == "1" ]]; then
    echo "========== PCE RESPONSE =========="
    cat /tmp/illumio-put-response.json
    echo
    echo "=================================="
fi

echo "DONE"