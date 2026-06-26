#!/bin/bash
# TG alert sender (GRA monitor). Local-config variant of the MSK telegram-alert.sh.
# Sources chameleon-alerts.env from THIS dir (copied from MSK /etc/chameleon-alerts.env).
# Usage: ./telegram-alert.sh "message"
set -euo pipefail
CONFIG="$(cd "$(dirname "$0")" && pwd)/chameleon-alerts.env"
[ -f "$CONFIG" ] && source "$CONFIG"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"; CHAT_IDS="${TELEGRAM_CHAT_IDS:-}"
if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_IDS" ]; then echo "telegram-alert: missing creds in $CONFIG"; exit 1; fi
MSG="$1"
for CID in $CHAT_IDS; do
    curl -sf -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="$CID" -d text="$MSG" -d parse_mode="HTML" --max-time 10 >/dev/null 2>&1 || true
done
