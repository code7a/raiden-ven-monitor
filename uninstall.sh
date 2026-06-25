#!/bin/bash

set -euo pipefail

echo "Removing Project Raiden..."

rm -rf /opt/illumio-ai-monitor
rm -rf /etc/illumio-ai-monitor

crontab -l 2>/dev/null | grep -v monitor.sh | crontab -

echo "Uninstall complete."