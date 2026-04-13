#!/bin/bash
# Chameleon VPN — Deploy Go backend to any node
# Usage: ./deploy.sh <node> [--with-singbox]
#   node: de, nl, all
#   --with-singbox: also restart singbox (causes brief VPN drop!)
#
# sing-box runs OUTSIDE docker-compose as a standalone container.
# Normal deploys NEVER touch singbox — VPN connections survive.
set -euo pipefail

NODE="${1:-}"
WITH_SINGBOX=0
for arg in "$@"; do
    [ "$arg" = "--with-singbox" ] && WITH_SINGBOX=1
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Node registry ─────────────────────────────────────────────────────────
get_node_config() {
    case "$1" in
        de)
            NODE_SSH="ubuntu@162.19.242.30"
            NODE_DIR="/opt/chameleon"
            NODE_NODE_ID="de-1"
            NODE_SNI="ads.adfox.ru"
            NODE_PREBUILT=0
            ;;
        nl)
            NODE_SSH="root@194.135.38.90"
            NODE_DIR="/opt/chameleon"
            NODE_NODE_ID="nl-1"
            NODE_SNI="ads.adfox.ru"
            NODE_PREBUILT=1  # 2GB RAM — can't compile Go in Docker
            ;;
        all)
            "$0" de "${@:2}"
            "$0" nl "${@:2}"
            exit 0
            ;;
        *)
            echo "Usage: $0 <de|nl|all> [--with-singbox]"
            exit 1
            ;;
    esac
}

get_node_config "$NODE"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Deploying Chameleon to ${NODE} (${NODE_SSH})"
[ "$WITH_SINGBOX" -eq 1 ] && echo "║  ⚠  --with-singbox: will restart VPN!"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Load secrets ───────────────────────────────────────────────────────────
source ~/.secrets.env

# ── Cross-compile if needed ────────────────────────────────────────────────
if [ "$NODE_PREBUILT" -eq 1 ]; then
    echo ">>> Cross-compiling Go binary for linux/amd64..."
    cd "$SCRIPT_DIR"
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
        -trimpath -ldflags="-s -w" \
        -o chameleon-linux ./cmd/chameleon
    echo ">>> Binary ready: $(ls -lh chameleon-linux | awk '{print $5}')"
    cd "$PROJECT_DIR"
fi

# ── Sync files ─────────────────────────────────────────────────────────────
echo ">>> Syncing files to ${NODE_SSH}:${NODE_DIR}..."
rsync -avz --delete \
    --exclude='.git' \
    --exclude='backend-go/chameleon' \
    --exclude='backend-go/ascinit' \
    --exclude='.env' \
    --exclude='backend-go/.env' \
    --exclude='backend-go/config.yaml' \
    --exclude='node_modules' \
    --exclude='target' \
    -e ssh \
    "${PROJECT_DIR}/" \
    "${NODE_SSH}:${NODE_DIR}/"

# ── Remote deploy ──────────────────────────────────────────────────────────
echo ">>> Running deploy on ${NODE_SSH}..."
ssh "${NODE_SSH}" bash -s -- \
    "${CHAMELEON_DB_PASSWORD}" \
    "${CHAMELEON_REDIS_PASSWORD}" \
    "${CHAMELEON_ADMIN_JWT_SECRET}" \
    "${CHAMELEON_ADMIN_PASSWORD}" \
    "${CHAMELEON_USER_API_SECRET}" \
    "${CHAMELEON_CLUSTER_SECRET:-}" \
    "${NODE_NODE_ID}" \
    "${NODE_SNI}" \
    "${NODE_DIR}" \
    "${NODE_PREBUILT}" \
    "${WITH_SINGBOX}" \
    "${BOT_TOKEN:-}" \
    "${ADMIN_IDS:-170181045 6668749877}" \
    <<'REMOTE'
set -euo pipefail

DB_PASSWORD="$1"
REDIS_PASSWORD="$2"
JWT_SECRET="$3"
ADMIN_PASSWORD="$4"
USER_API_SECRET="$5"
CLUSTER_SECRET="$6"
NODE_ID="$7"
NODE_SNI="$8"
REMOTE_DIR="$9"
PREBUILT="${10}"
WITH_SINGBOX="${11}"
TG_BOT_TOKEN="${12}"
TG_CHAT_IDS="${13}"

cd "${REMOTE_DIR}/backend-go"

# ── Config ─────────────────────────────────────────────────────────────────
cp config.production.yaml config.yaml
sed -i "s/node_id: \"\"/node_id: \"${NODE_ID}\"/" config.yaml
sed -i "s/default: \"ads.adfox.ru\"/default: \"${NODE_SNI}\"/" config.yaml

# Set cluster peers (each node points to all other nodes)
case "$NODE_ID" in
    de-1) PEER_BLOCK='  peers:\n    - id: "nl-1"\n      url: "http://194.135.38.90:8000"' ;;
    nl-1) PEER_BLOCK='  peers:\n    - id: "de-1"\n      url: "http://162.19.242.30:8000"' ;;
    *) PEER_BLOCK='  peers: []' ;;
esac
sed -i "s|  peers: \[\]|${PEER_BLOCK}|" config.yaml
echo ">>> Cluster sync enabled (node=${NODE_ID}, peers configured)"

# .env — Reality keys are in DB now, not here
cat > .env <<EOF
DB_PASSWORD=${DB_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
JWT_SECRET=${JWT_SECRET}
USER_API_SECRET=${USER_API_SECRET}
CLUSTER_SECRET=${CLUSTER_SECRET}
EOF
chmod 600 .env

# Telegram alerts config
if [ -n "$TG_BOT_TOKEN" ]; then
    printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_IDS="%s"\n' \
        "${TG_BOT_TOKEN}" "${TG_CHAT_IDS}" \
        | sudo tee /etc/chameleon-alerts.env > /dev/null
    sudo chmod 644 /etc/chameleon-alerts.env
    echo ">>> Telegram alerts configured"
fi

# ── Run migration ──────────────────────────────────────────────────────────
echo ">>> Running DB migrations..."
for f in migrations/0[0-9][0-9]_*.sql; do
    [ -f "$f" ] && docker exec -i chameleon-postgres psql -U chameleon -d chameleon < "$f" 2>/dev/null && echo "    Applied: $f"
done

# ── Docker volumes ─────────────────────────────────────────────────────────
docker volume create chameleon-pgdata 2>/dev/null || true
docker volume create chameleon-redisdata 2>/dev/null || true
docker volume create chameleon-singbox-config 2>/dev/null || true

# ── Build chameleon ────────────────────────────────────────────────────────
if [ "$PREBUILT" -eq 1 ]; then
    echo ">>> Building from pre-compiled binary..."
    docker build -f Dockerfile.prebuilt -t backend-go-chameleon . 2>&1 | tail -3
else
    echo ">>> Building from source..."
    docker compose build chameleon 2>&1 | tail -5
fi

# ── Build nginx (skip if exists) ───────────────────────────────────────────
if docker image inspect backend-go-nginx >/dev/null 2>&1 || docker image inspect chameleon-nginx >/dev/null 2>&1; then
    echo ">>> Nginx image exists, skipping rebuild"
else
    echo ">>> Building nginx (admin SPA)..."
    docker compose build nginx 2>&1 | tail -5
fi

# ── Restart chameleon ONLY (singbox is standalone, compose can't touch it) ─
echo ">>> Starting chameleon + nginx..."
docker compose up -d --no-deps chameleon
docker compose up -d nginx

# ── Wait for health ────────────────────────────────────────────────────────
echo ">>> Waiting for backend health..."
for i in $(seq 1 90); do
    if wget -qO- http://localhost:8000/health 2>/dev/null | grep -q '"status"'; then
        echo ">>> Backend is healthy!"
        break
    fi
    if [ "$i" -eq 90 ]; then
        echo ">>> ERROR: Backend did not become healthy in 90s"
        docker compose logs chameleon --tail 50
        exit 1
    fi
    sleep 1
done

# ── Create admin user (idempotent) ─────────────────────────────────────────
docker compose exec -T chameleon chameleon admin create \
    --config /etc/chameleon/config.yaml \
    --username admin --password "${ADMIN_PASSWORD}" --role admin 2>/dev/null || true

# ── Singbox (only if --with-singbox) ───────────────────────────────────────
if [ "$WITH_SINGBOX" -eq 1 ]; then
    echo ">>> Restarting singbox (VPN will briefly drop)..."
    chmod +x scripts/singbox-run.sh
    ./scripts/singbox-run.sh --force
fi

# ── Install watchdog cron (idempotent) ─────────────────────────────────────
chmod +x "${REMOTE_DIR}/backend-go/scripts/"*.sh 2>/dev/null || true

# Watchdog cron (every minute) — installed as ROOT so the script can write
# /var/log/ and doesn't need interactive sudo for `test -f` on docker volume.
# Previously installed under ubuntu user → log file never created and sudo calls
# inside the script failed silently, letting singbox stay dead indefinitely.
WATCHDOG="${REMOTE_DIR}/backend-go/scripts/singbox-watchdog.sh"
if [ -f "$WATCHDOG" ]; then
    CRON_LINE="* * * * * ${WATCHDOG} >> /var/log/singbox-watchdog.log 2>&1"
    sudo bash -c "(crontab -l 2>/dev/null | grep -v 'singbox-watchdog' ; echo '$CRON_LINE') | crontab -"
    # Also remove stale user-level cron from earlier deploys.
    (crontab -l 2>/dev/null | grep -v "singbox-watchdog") | crontab - 2>/dev/null || true
    echo ">>> Watchdog cron installed (root)"
fi

# Health check cron (every minute) — also root for the same reason.
HEALTHCHECK="${REMOTE_DIR}/backend-go/scripts/health-check.sh"
if [ -f "$HEALTHCHECK" ]; then
    CRON_LINE="* * * * * ${HEALTHCHECK} >> /var/log/chameleon-health.log 2>&1"
    sudo bash -c "(crontab -l 2>/dev/null | grep -v 'health-check' ; echo '$CRON_LINE') | crontab -"
    (crontab -l 2>/dev/null | grep -v "health-check") | crontab - 2>/dev/null || true
    echo ">>> Health check cron installed (root)"
fi

# DB backup cron (daily at 3:00 AM)
BACKUP="${REMOTE_DIR}/backend-go/scripts/db-backup.sh"
if [ -f "$BACKUP" ]; then
    CRON_LINE="0 3 * * * ${BACKUP} >> /var/log/chameleon-backup.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "db-backup" ; echo "$CRON_LINE") | crontab -
    echo ">>> DB backup cron installed (daily 3:00 AM)"
fi

# ── Post-deploy verification ──────────────────────────────────────────────
echo ""
echo "╔═══ POST-DEPLOY CHECKS ═══╗"

# Check chameleon
if wget -qO- http://localhost:8000/health 2>/dev/null | grep -q '"status":"ok"'; then
    echo "║ ✓ Chameleon API: OK"
else
    echo "║ ✗ Chameleon API: FAIL"
fi

# Check singbox container — auto-start if it exists but is stopped.
# Reason: `unless-stopped` policy does NOT auto-restart after manual docker stop,
# so a leftover stopped singbox from a previous session silently breaks VPN.
if docker ps --filter "name=singbox" --filter "status=running" -q | grep -q .; then
    echo "║ ✓ Singbox container: RUNNING"
elif docker ps -a --filter "name=singbox" -q | grep -q .; then
    echo "║ ⚠ Singbox container: STOPPED — auto-starting..."
    if docker start singbox >/dev/null 2>&1; then
        sleep 2
        if docker ps --filter "name=singbox" --filter "status=running" -q | grep -q .; then
            echo "║ ✓ Singbox container: RECOVERED"
        else
            echo "║ ✗ Singbox container: FAILED TO START"
            docker logs singbox --tail 20
        fi
    else
        echo "║ ✗ Singbox container: docker start failed"
    fi
else
    echo "║ ✗ Singbox container: NOT FOUND"
    echo "║   Run: ./scripts/singbox-run.sh"
fi

# Check User API
if curl -sf http://127.0.0.1:15380/api/v1/inbounds -o /dev/null 2>/dev/null; then
    echo "║ ✓ User API (15380): OK"
else
    echo "║ ✗ User API (15380): NOT RESPONDING"
fi

# Check VPN port
if ss -tlnp 2>/dev/null | grep -q ':2096' || netstat -tlnp 2>/dev/null | grep -q ':2096'; then
    echo "║ ✓ VPN port 2096: LISTENING"
else
    echo "║ ✗ VPN port 2096: NOT LISTENING"
fi

# Check clash API
if curl -sf http://127.0.0.1:9090/ -o /dev/null 2>/dev/null; then
    echo "║ ✓ Clash API (9090): OK"
else
    echo "║ ✗ Clash API (9090): NOT RESPONDING"
fi

echo "╚══════════════════════════╝"
echo ""
echo ">>> Deploy complete!"
REMOTE

# Cleanup local binary
if [ "$NODE_PREBUILT" -eq 1 ] && [ -f "$SCRIPT_DIR/chameleon-linux" ]; then
    rm "$SCRIPT_DIR/chameleon-linux"
fi

echo "=== Done: ${NODE} deployed ==="
