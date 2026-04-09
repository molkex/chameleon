#!/bin/bash
# Singbox watchdog — checks if singbox container is running, restarts if not.
# Install: crontab -e → * * * * * /path/to/singbox-watchdog.sh >> /var/log/singbox-watchdog.log 2>&1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINER="singbox"
IMAGE="sing-box-fork:v1.13.6-userapi"
VOLUME="chameleon-singbox-config"
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"

# Check if running
if docker ps --filter "name=${CONTAINER}" --filter "status=running" -q | grep -q .; then
    exit 0  # healthy, nothing to do
fi

echo "${LOG_PREFIX} singbox container not running — attempting restart..."

# Remove dead container if exists
docker rm -f "$CONTAINER" 2>/dev/null || true

# Check config file exists
CONFIG_PATH=$(docker volume inspect "$VOLUME" --format '{{.Mountpoint}}')/singbox-config.json
if [ ! -f "$CONFIG_PATH" ]; then
    echo "${LOG_PREFIX} WARNING: config file not found at ${CONFIG_PATH}, skipping restart"
    exit 1
fi

# Start
docker run -d \
    --name "$CONTAINER" \
    --restart unless-stopped \
    --network host \
    --cap-add NET_ADMIN \
    --cap-add NET_BIND_SERVICE \
    --security-opt no-new-privileges:true \
    -v "${VOLUME}:/etc/singbox:ro" \
    "$IMAGE" \
    run -c /etc/singbox/singbox-config.json

# Wait and verify
sleep 3
if docker ps --filter "name=${CONTAINER}" --filter "status=running" -q | grep -q .; then
    echo "${LOG_PREFIX} singbox restarted successfully"
    # Alert: singbox was down but recovered
    [ -x "$SCRIPT_DIR/telegram-alert.sh" ] && \
        "$SCRIPT_DIR/telegram-alert.sh" "🟡 <b>$HOSTNAME</b>: singbox was down, watchdog restarted it" || true
else
    echo "${LOG_PREFIX} ERROR: singbox failed to start!"
    docker logs "$CONTAINER" --tail 10 2>&1
    # Alert: singbox failed to start
    [ -x "$SCRIPT_DIR/telegram-alert.sh" ] && \
        "$SCRIPT_DIR/telegram-alert.sh" "🔴 <b>$HOSTNAME</b>: singbox FAILED to start! Manual intervention needed" || true
fi
