#!/bin/bash
# Chameleon VPN — Deploy Go backend to DE server
# Usage: ./deploy.sh
set -euo pipefail

SERVER="ubuntu@162.19.242.30"
REMOTE_DIR="/home/ubuntu/chameleon"

# Source secrets from local machine
source ~/.secrets.env

echo "=== Deploying Chameleon Go backend to DE ==="

# 1. Sync entire project to server
echo ">>> Syncing files..."
rsync -avz --delete \
    --exclude='.git' \
    --exclude='backend-go/chameleon' \
    --exclude='.env' \
    --exclude='node_modules' \
    --exclude='backend-go/.env' \
    -e ssh \
    "$(cd "$(dirname "$0")/.." && pwd)/" \
    "${SERVER}:${REMOTE_DIR}/"

# 2. Deploy on server
echo ">>> Running deploy on server..."
ssh "${SERVER}" bash -s -- \
    "${CHAMELEON_DB_PASSWORD}" \
    "${CHAMELEON_REDIS_PASSWORD}" \
    "${CHAMELEON_ADMIN_JWT_SECRET}" \
    "${CHAMELEON_REALITY_PRIVATE_KEY}" \
    "${CHAMELEON_REALITY_PUBLIC_KEY}" \
    "${CHAMELEON_ADMIN_PASSWORD}" \
    <<'REMOTE'
set -euo pipefail

DB_PASSWORD="$1"
REDIS_PASSWORD="$2"
JWT_SECRET="$3"
REALITY_PRIVATE_KEY="$4"
REALITY_PUBLIC_KEY="$5"
ADMIN_PASSWORD="$6"

cd /home/ubuntu/chameleon/backend-go

# Stop old Rust backend (if running)
echo ">>> Stopping old backend..."
cd /home/ubuntu/chameleon/backend
docker compose down --remove-orphans 2>/dev/null || true
cd /home/ubuntu/chameleon/backend-go

# Copy production config
cp config.production.yaml config.yaml

# Create .env with secrets
cat > .env <<EOF
DB_PASSWORD=${DB_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
JWT_SECRET=${JWT_SECRET}
REALITY_PRIVATE_KEY=${REALITY_PRIVATE_KEY}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
EOF
chmod 600 .env

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

# Create admin user (idempotent — will fail silently if exists)
echo ">>> Creating admin user..."
docker compose exec -T chameleon chameleon admin create \
    --config /etc/chameleon/config.yaml \
    --username admin \
    --password "${ADMIN_PASSWORD}" \
    --role admin 2>/dev/null || echo "(admin may already exist)"

echo ">>> Deploy complete!"
docker compose ps
REMOTE

echo "=== Done ==="
