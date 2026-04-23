#!/bin/bash
# Send alert to Telegram admins. Usage: ./telegram-alert.sh "message text"
# Config: /etc/chameleon-alerts.env (deployed by deploy.sh)
set -euo pipefail

CONFIG="/etc/chameleon-alerts.env"
if [ -f "$CONFIG" ]; then
    source "$CONFIG"
fi

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_IDS="${TELEGRAM_CHAT_IDS:-}"

if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_IDS" ]; then
    echo "telegram-alert: missing TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_IDS in $CONFIG"
    exit 1
fi

MESSAGE="$1"

for CHAT_ID in $CHAT_IDS; do
    curl -sf -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d text="$MESSAGE" \
        -d parse_mode="HTML" \
        --max-time 10 >/dev/null 2>&1 || true
done
