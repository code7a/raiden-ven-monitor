# Project Raiden
Lightweight real-time AI log analysis and event notification for Illumio VEN

---

## Overview

Project Raiden is a lightweight, real-time log analysis system for Illumio VEN that uses a local AI model to extract actionable issues, assign severity, and generate recommendations.

It monitors VEN logs, filters noise, identifies meaningful signals, and publishes structured results back to the PCE using workload external data.

This is designed to be:
- fast
- lightweight
- simple to deploy
- easy to understand and extend

---

## Key Characteristics

- Local AI only — no data is sent to external or third-party services
- Uses Ollama + Qwen model running locally
- Focused on signal extraction, not full observability
- Designed for low resource usage and predictable behavior

---

## What It Currently Monitors

The script currently analyzes these VEN logs:

- platform.log
- agentmgr.log
- event.log

This can be expanded in the future to include additional logs or data sources.

---

## How It Works

1. Collects and filters VEN logs
2. Removes noise
3. Sends filtered logs to a local AI model (Qwen via Ollama)
4. Extracts structured JSON:
   - severity
   - issue
   - recommendation
5. Applies validation and fallback logic
6. Compacts output to meet PCE API limits
7. Updates workload external_data_set via API

---

## Architecture

VEN Logs → Filter → AI (Ollama / Qwen) → Normalize → PCE Update

---

## Installation

Clone the repository:

git clone https://github.com/code7a/raiden-ven-monitor.git
cd raiden-ven-monitor  

Run the installer:

sudo ./install.sh

You will be prompted for:

- Illumio API Key  
- Illumio API Secret  

Requirements:
- API key must have permissions to update workloads
- Must be run as root (installs system paths and cron job)
- Linux host with Illumio VEN installed

---

## Uninstall

sudo ./uninstall.sh

Removes:
- installed scripts
- configuration files
- cron job

---

## Running and Debugging

Run manually with debug enabled:

DEBUG=1 /opt/illumio-ai-monitor/monitor.sh

This will show:
- raw AI output
- parsed JSON
- processing flow

---

## Scheduling

The installer creates a cron job:

*/10 * * * * /opt/illumio-ai-monitor/monitor.sh >/dev/null 2>&1

Runs every 10 minutes to reduce compute usage.

---

## Real-Time Operation (Future)

Currently runs on a schedule.

Can be extended to:
- run continuously
- tail logs in real time
- stream events for immediate detection

---

## AI Model Details

Uses:
- Ollama (local runtime)
- Qwen 2.5 (1.5B)

Reasoning:
- small and fast
- strong instruction following
- works well with structured prompts
- no external dependencies

---

## Current Limitations

- Only monitors 3 VEN logs
- Uses workload external_data_set as output channel
- Not a full SIEM or observability platform
- Output is single-issue focused
- Behavior depends on log quality and model interpretation

---

## Future Improvements

- Expand monitored log sources
- Improve issue summarization / normalization
- Real-time streaming mode
- Alternative output mechanisms (alerts, webhooks, etc.)

---

## Security / Data Handling

- All processing is local
- No logs or data leave the system
- No external AI services are used

---

## Status

This project is:

BETA

- Not officially supported
- Use at your own risk
- Behavior may change as prompts and models improve

---

## Naming

Raiden stands for:

Real-time AI Driven Event Notification

---

## License

This project uses the Apache License (see LICENSE file)