#!/bin/bash
# Health check — runs every minute via cron
# Checks: chameleon API, singbox container, VPN port
# Sends Telegram alert on failure (rate-limited: 1 per 5 min per issue)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
ALERT_INTERVAL=300
STATE_DIR="/tmp/chameleon-health"
mkdir -p "$STATE_DIR"

alert() {
    local key="$1" msg="$2"
    local last_file="$STATE_DIR/$key"
    local now=$(date +%s)
    if [ -f "$last_file" ]; then
        local last=$(cat "$last_file")
        if [ $((now - last)) -lt $ALERT_INTERVAL ]; then
            return
        fi
    fi
    echo "$now" > "$last_file"
    "$SCRIPT_DIR/telegram-alert.sh" "$msg"
}

clear_alert() {
    rm -f "$STATE_DIR/$1"
}

# Check chameleon API
if wget -qO- http://localhost:8000/health 2>/dev/null | grep -q '"status":"ok"'; then
    clear_alert "chameleon"
else
    alert "chameleon" "⚠️ <b>$HOSTNAME</b>: Chameleon API health check FAILED"
fi

# Check singbox container
if docker ps --filter "name=singbox" --filter "status=running" -q 2>/dev/null | grep -q .; then
    clear_alert "singbox"
else
    alert "singbox" "🔴 <b>$HOSTNAME</b>: singbox container NOT RUNNING"
fi

# Check VPN port
if ss -tlnp 2>/dev/null | grep -q ':2096' || netstat -tlnp 2>/dev/null | grep -q ':2096'; then
    clear_alert "vpn-port"
else
    alert "vpn-port" "🔴 <b>$HOSTNAME</b>: VPN port 2096 NOT LISTENING"
fi
