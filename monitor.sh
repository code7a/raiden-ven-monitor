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
'YOU MUST ONLY RETURN valid JSON. No markdown, no extra text.' \
'Output MUST start with { and end with }.' \
'' \
'OUTPUT FORMAT:' \
'{"timestamp":"'"$AI_TS"'","severity":"low","confidence":0.0,"issue":"","recommendation":""}' \
'' \
'Severity MUST be exactly one of: low, medium, high, critical' \
'' \
'SEVERITY RULES:' \
'- critical = confirmed compromise or active attack' \
'- high = enforcement or security failure' \
'- medium = repeated operational failure' \
'- low = isolated or recoverable issue' \
'' \
'LOG INTERPRETATION RULES:' \
'- ERROR indicates a problem' \
'- WARN indicates a potential issue' \
'- FAIL indicates failure' \
'- INFO is normal unless failures repeat' \
'- PASS means success and is not a failure' \
'- If multiple ERROR events exist, treat as a persistent issue even if recovery messages appear' \
'- If ANY ERROR messages are present, issue MUST describe the most important error even if recovery occurs' \
'' \
'STRICT OUTPUT RULES:' \
'- If ANY ERROR is present, issue MUST NOT be empty' \
'- If ANY ERROR is present, recommendation MUST NOT be empty' \
'- issue MUST NOT be empty if severity is not low' \
'- recommendation MUST NOT be empty if severity is not low' \
'- issue max 120 chars' \
'- recommendation max 160 chars' \
'- do not include full file paths' \
'- do not include stack traces' \
'- prefer summarized root cause, not raw logs' \
'' \
'If no meaningful issues:' \
'{"timestamp":"'"$AI_TS"'","severity":"low","confidence":0.0,"issue":"No actionable issue detected","recommendation":"No action required"}' \
'' \
'LOGS:' \
> "$RAW_INPUT"

cat "$OUTFILE" >> "$RAW_INPUT"

# -----------------------------
# RUN MODEL
# -----------------------------
timeout 120 ollama run qwen2.5:1.5b --nowordwrap < "$RAW_INPUT" > "$RAW_MODEL" 2>/dev/null || {
  JSON='{"timestamp":"'"$AI_TS"'","severity":"low","confidence":0.2,"issue":"analysis_failed","recommendation":"Monitor logs"}'
}

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

EXT_DS="$JSON_OUT"

PAYLOAD=$(jq -n \
  --arg ds "$EXT_DS" \
  '{external_data_set:$ds,external_data_reference:"Raiden Wins!"}')

debug "Payload external_data_set bytes: $(printf '%s' "$EXT_DS" | wc -c | tr -d ' ')"

echo "PUSHING TO PCE..."

curl -sk -X PUT \
  -u "${API_KEY}:${API_SECRET}" \
  -H "Content-Type: application/json" \
  "$PCE_URL" \
  -d "$PAYLOAD"

echo "DONE"