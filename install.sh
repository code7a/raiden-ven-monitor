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
read -p "Enter Illumio API Key: " API_KEY
read -s -p "Enter Illumio API Secret: " API_SECRET
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
ollama pull qwen2.5:1.5b

echo "[*] Creating directories..."
mkdir -p /etc/illumio-ai-monitor
mkdir -p /opt/illumio-ai-monitor/output

echo "[*] Writing API config..."
cat > /etc/illumio-ai-monitor/api.conf <<EOF
API_KEY=$API_KEY
API_SECRET=$API_SECRET
EOF

chmod 600 /etc/illumio-ai-monitor/api.conf

echo "[*] Installing monitor script..."
cp ./monitor.sh /opt/illumio-ai-monitor/monitor.sh
chmod +x /opt/illumio-ai-monitor/monitor.sh

echo "[*] Setting up cron (every 10 minutes)..."
(crontab -l 2>/dev/null | grep -v monitor.sh; echo "*/10 * * * * /opt/illumio-ai-monitor/monitor.sh >/dev/null 2>&1") | crontab -

echo ""
echo "Install complete."
echo "Run a test with:"
echo "  DEBUG=1 /opt/illumio-ai-monitor/monitor.sh"