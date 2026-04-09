#!/bin/bash
# Chameleon VPN — Deploy Go backend to any node
# Usage: ./deploy.sh <node>
#   node: de, nl (or any key defined below)
#
# Each node is an autonomous instance: Go backend + sing-box + PostgreSQL + Redis.
# Secrets are read from ~/.secrets.env on the local machine.
set -euo pipefail

NODE="${1:-}"

# ── Node registry (compatible with bash 3.2+) ─────────────────────────────
get_node_config() {
    case "$1" in
        de)
            NODE_SSH="ubuntu@162.19.242.30"
            NODE_DIR="/home/ubuntu/chameleon"
            NODE_NODE_ID="de-1"
            NODE_SNI="ads.adfox.ru"
            ;;
        nl)
            NODE_SSH="root@194.135.38.90"
            NODE_DIR="/root/chameleon"
            NODE_NODE_ID="nl-1"
            NODE_SNI="ads.adfox.ru"
            ;;
        *)
            echo "Usage: $0 <node>"
            echo "Available nodes: de nl"
            exit 1
            ;;
    esac
}

get_node_config "$NODE"

echo "=== Deploying Chameleon to ${NODE} (${NODE_SSH}) ==="

# ── Load secrets ───────────────────────────────────────────────────────────
source ~/.secrets.env

# Node-specific Reality keys (fallback to shared keys)
NODE_UPPER=$(echo "$NODE" | tr '[:lower:]' '[:upper:]')
PRIV_VAR="CHAMELEON_REALITY_PRIVATE_KEY_${NODE_UPPER}"
PUB_VAR="CHAMELEON_REALITY_PUBLIC_KEY_${NODE_UPPER}"
REALITY_PRIV="${!PRIV_VAR:-${CHAMELEON_REALITY_PRIVATE_KEY}}"
REALITY_PUB="${!PUB_VAR:-${CHAMELEON_REALITY_PUBLIC_KEY}}"

# ── Sync files ─────────────────────────────────────────────────────────────
echo ">>> Syncing files to ${NODE_SSH}:${NODE_DIR}..."
rsync -avz --delete \
    --exclude='.git' \
    --exclude='backend-go/chameleon' \
    --exclude='.env' \
    --exclude='backend-go/.env' \
    --exclude='node_modules' \
    -e ssh \
    "$(cd "$(dirname "$0")/.." && pwd)/" \
    "${NODE_SSH}:${NODE_DIR}/"

# ── Remote deploy ──────────────────────────────────────────────────────────
echo ">>> Running deploy on ${NODE_SSH}..."
ssh "${NODE_SSH}" bash -s -- \
    "${CHAMELEON_DB_PASSWORD}" \
    "${CHAMELEON_REDIS_PASSWORD}" \
    "${CHAMELEON_ADMIN_JWT_SECRET}" \
    "${REALITY_PRIV}" \
    "${REALITY_PUB}" \
    "${CHAMELEON_ADMIN_PASSWORD}" \
    "${NODE_NODE_ID}" \
    "${NODE_SNI}" \
    "${NODE_DIR}" \
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

# Patch node-specific fields
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
