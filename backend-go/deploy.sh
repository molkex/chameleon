#!/bin/bash
# Chameleon VPN — Deploy Go backend to any node
# Usage: ./deploy.sh <node>
#   node: de, nl (or any key defined below)
#
# Each node is an autonomous instance: Go backend + sing-box + PostgreSQL + Redis.
# Secrets are read from ~/.secrets.env on the local machine.
set -euo pipefail

# ── Node registry ──────────────────────────────────────────────────────────
# Add new nodes here. Format: SSH_TARGET REMOTE_DIR NODE_ID SNI
declare -A NODE_SSH NODE_DIR NODE_ID NODE_SNI
NODE_SSH[de]="ubuntu@162.19.242.30"
NODE_DIR[de]="/home/ubuntu/chameleon"
NODE_ID[de]="de-1"
NODE_SNI[de]="ads.adfox.ru"

NODE_SSH[nl]="root@194.135.38.90"
NODE_DIR[nl]="/root/chameleon"
NODE_ID[nl]="nl-1"
NODE_SNI[nl]="ads.adfox.ru"

# ── Parse arguments ────────────────────────────────────────────────────────
NODE="${1:-}"
if [[ -z "$NODE" ]] || [[ -z "${NODE_SSH[$NODE]+x}" ]]; then
    echo "Usage: $0 <node>"
    echo "Available nodes: ${!NODE_SSH[*]}"
    exit 1
fi

SERVER="${NODE_SSH[$NODE]}"
REMOTE_DIR="${NODE_DIR[$NODE]}"
DEPLOY_NODE_ID="${NODE_ID[$NODE]}"
DEPLOY_SNI="${NODE_SNI[$NODE]}"

echo "=== Deploying Chameleon to ${NODE} (${SERVER}) ==="

# ── Load secrets ───────────────────────────────────────────────────────────
source ~/.secrets.env

# Node-specific Reality keys (fallback to shared keys)
PRIV_VAR="CHAMELEON_REALITY_PRIVATE_KEY_${NODE^^}"
PUB_VAR="CHAMELEON_REALITY_PUBLIC_KEY_${NODE^^}"
REALITY_PRIV="${!PRIV_VAR:-${CHAMELEON_REALITY_PRIVATE_KEY}}"
REALITY_PUB="${!PUB_VAR:-${CHAMELEON_REALITY_PUBLIC_KEY}}"

# ── Sync files ─────────────────────────────────────────────────────────────
echo ">>> Syncing files to ${SERVER}:${REMOTE_DIR}..."
rsync -avz --delete \
    --exclude='.git' \
    --exclude='backend-go/chameleon' \
    --exclude='backend/target' \
    --exclude='backend/node_modules' \
    --exclude='.env' \
    --exclude='backend-go/.env' \
    --exclude='node_modules' \
    -e ssh \
    "$(cd "$(dirname "$0")/.." && pwd)/" \
    "${SERVER}:${REMOTE_DIR}/"

# ── Remote deploy ──────────────────────────────────────────────────────────
echo ">>> Running deploy on ${SERVER}..."
ssh "${SERVER}" bash -s -- \
    "${CHAMELEON_DB_PASSWORD}" \
    "${CHAMELEON_REDIS_PASSWORD}" \
    "${CHAMELEON_ADMIN_JWT_SECRET}" \
    "${REALITY_PRIV}" \
    "${REALITY_PUB}" \
    "${CHAMELEON_ADMIN_PASSWORD}" \
    "${DEPLOY_NODE_ID}" \
    "${DEPLOY_SNI}" \
    "${REMOTE_DIR}" \
    <<'REMOTE'
set -euo pipefail

DB_PASSWORD="$1"
REDIS_PASSWORD="$2"
JWT_SECRET="$3"
REALITY_PRIVATE_KEY="$4"
REALITY_PUBLIC_KEY="$5"
ADMIN_PASSWORD="$6"
NODE_ID="$7"
NODE_SNI="$8"
REMOTE_DIR="$9"

cd "${REMOTE_DIR}/backend-go"

# Generate config.yaml from template with node-specific values
cp config.production.yaml config.yaml

# Patch node-specific fields via sed
sed -i "s/node_id: \"\"/node_id: \"${NODE_ID}\"/" config.yaml
sed -i "s/default: \"ads.adfox.ru\"/default: \"${NODE_SNI}\"/" config.yaml

# Create .env with secrets (docker-compose reads this)
cat > .env <<EOF
DB_PASSWORD=${DB_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
JWT_SECRET=${JWT_SECRET}
REALITY_PRIVATE_KEY=${REALITY_PRIVATE_KEY}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
EOF
chmod 600 .env

# Ensure Docker volumes exist
docker volume create chameleon-pgdata 2>/dev/null || true
docker volume create chameleon-redisdata 2>/dev/null || true

# Build and start
echo ">>> Building and starting services..."
docker compose build --no-cache
docker compose up -d

# Wait for backend health
echo ">>> Waiting for backend health..."
for i in $(seq 1 60); do
    if wget -qO- http://localhost:8000/health 2>/dev/null | grep -q '"status"'; then
        echo ">>> Backend is healthy!"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo ">>> ERROR: Backend did not become healthy in 60s"
        docker compose logs chameleon --tail 50
        exit 1
    fi
    sleep 1
done

# Create admin user (idempotent)
echo ">>> Creating admin user..."
docker compose exec -T chameleon chameleon admin create \
    --config /etc/chameleon/config.yaml \
    --username admin \
    --password "${ADMIN_PASSWORD}" \
    --role admin 2>/dev/null || echo "(admin may already exist)"

echo ">>> Deploy complete!"
docker compose ps
REMOTE

echo "=== Done: ${NODE} deployed ==="
