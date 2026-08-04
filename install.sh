#!/bin/bash

set -euo pipefail

echo "======================================"
echo "Project Raiden Installer"
echo "======================================"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)"
  exit 1
fi

echo ""
API_KEY="${API_KEY:-}"
API_SECRET="${API_SECRET:-}"

if [[ -z "$API_KEY" ]]; then
  read -p "Enter Illumio API Key: " API_KEY
fi

if [[ -z "$API_SECRET" ]]; then
  read -s -p "Enter Illumio API Secret: " API_SECRET
  echo ""
fi
echo ""

if [[ -z "$API_KEY" || -z "$API_SECRET" ]]; then
  echo "API credentials cannot be empty"
  exit 1
fi

echo "[*] Installing dependencies..."
dnf install -y zstd jq curl

if ! command -v ollama >/dev/null 2>&1; then
  echo "[*] Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
fi

echo "[*] Pulling model..."

export HOME=/root

if ! pgrep -x ollama >/dev/null 2>&1; then
    echo "[*] Starting Ollama..."
    nohup /usr/local/bin/ollama serve >/var/log/ollama.log 2>&1 &
fi

for i in {1..30}; do
    if ollama list >/dev/null 2>&1; then
        break
    fi

    if [[ $i -eq 30 ]]; then
        echo "ERROR: Ollama failed to start"
        exit 1
    fi

    echo "[*] Waiting for Ollama..."
    sleep 2
done

ollama pull qwen2.5:1.5b

echo "[*] Creating directories..."
mkdir -p /etc/illumio-ai-monitor
mkdir -p /opt/illumio-ai-monitor/output

echo "INSTALL DEBUG:"
echo "API_KEY length=${#API_KEY}"
echo "API_SECRET length=${#API_SECRET}"

echo "[*] Writing API config..."
cat > /etc/illumio-ai-monitor/api.conf <<EOF
API_KEY=$API_KEY
API_SECRET=$API_SECRET
EOF

chmod 600 /etc/illumio-ai-monitor/api.conf

echo "[*] Installing monitor script..."
cp ./monitor.sh /opt/illumio-ai-monitor/monitor.sh
chmod +x /opt/illumio-ai-monitor/monitor.sh

echo "[*] Testing monitor script..."

if DEBUG=1 /opt/illumio-ai-monitor/monitor.sh; then
    echo "[*] monitor.sh test passed"
else
    echo "ERROR: monitor.sh failed initial test"
    exit 1
fi

echo "[*] Setting up cron (every 10 minutes)..."

cat >/etc/cron.d/illumio-ai-monitor <<'EOF'
*/10 * * * * root /opt/illumio-ai-monitor/monitor.sh >> /var/log/illumio-ai-monitor.log 2>&1
EOF

chmod 644 /etc/cron.d/illumio-ai-monitor

systemctl enable crond >/dev/null 2>&1 || true
systemctl restart crond

echo ""
echo "Install complete."
echo "Run a test with:"
echo "  DEBUG=1 /opt/illumio-ai-monitor/monitor.sh"