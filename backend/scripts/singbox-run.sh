#!/bin/bash
# Start singbox as standalone Docker container (outside docker-compose).
# Usage: ./singbox-run.sh [--force]
#   --force: remove existing container first
set -euo pipefail

CONTAINER="singbox"
IMAGE="sing-box-fork:v1.13.6-userapi"
VOLUME="chameleon-singbox-config"

if [ "${1:-}" = "--force" ]; then
    echo "Stopping and removing existing singbox container..."
    docker rm -f "$CONTAINER" 2>/dev/null || true
fi

if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "singbox is already running"
    docker ps --filter "name=${CONTAINER}" --format "table {{.Names}}\t{{.Status}}"
    exit 0
fi

# Remove stopped container if exists
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "Removing stopped singbox container..."
    docker rm "$CONTAINER"
fi

# Ensure config volume exists
docker volume create "$VOLUME" 2>/dev/null || true

echo "Starting singbox..."
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

sleep 2
echo "singbox started:"
docker ps --filter "name=${CONTAINER}" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
