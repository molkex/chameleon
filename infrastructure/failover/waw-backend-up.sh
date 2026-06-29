#!/usr/bin/env bash
# ============================================================
#  Bring up / rebuild the chameleon BACKEND on WAW (interim until deploy.sh
#  gains a proper `waw` node — ADR 0013 P1). Reproduces the 2026-06-29 failover
#  backend deterministically so it is no longer hand-assembled knowledge.
# ============================================================
# Run from the repo root with ~/.secrets.env present. Pushes a freshly
# cross-compiled binary + a generated env file, builds the prebuilt image, and
# (re)starts the chameleon-failover container against WAW's LOCAL postgres
# (the promoted primary) + a local redis. Idempotent.
#
# NOTE: WAW serves chameleon DIRECTLY on :8000 (no nginx yet). MSK upstream →
# 217.182.74.70:8000. failover.sh encodes that.
set -euo pipefail
cd "$(dirname "$0")/../../backend"
source ~/.secrets.env
W=debian@217.182.74.70; KEY=~/.ssh/claude-code-ssh-key
RX(){ ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "$W" "$@"; }

echo ">>> cross-compile binary"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /tmp/chameleon-linux ./cmd/chameleon

echo ">>> generate env file (exact container var names; secrets from ~/.secrets.env)"
cat > /tmp/chameleon-failover.env <<EOF
DB_PASSWORD=${CHAMELEON_DB_PASSWORD}
REDIS_PASSWORD=${CHAMELEON_REDIS_PASSWORD}
DATABASE_URL=postgres://chameleon:${CHAMELEON_DB_PASSWORD}@localhost:5432/chameleon?sslmode=disable
REDIS_URL=redis://:${CHAMELEON_REDIS_PASSWORD}@localhost:6379/0
JWT_SECRET=${CHAMELEON_ADMIN_JWT_SECRET}
USER_API_SECRET=${CHAMELEON_USER_API_SECRET}
CLUSTER_SECRET=${CHAMELEON_CLUSTER_SECRET}
CHAMELEON_PROVIDERS_ENCRYPTION_KEY=${CHAMELEON_PROVIDERS_ENCRYPTION_KEY}
CHAMELEON_MSK_USER_API_SECRET=${CHAMELEON_MSK_USER_API_SECRET}
FREEKASSA_SHOP_ID=${FREEKASSA_SHOP_ID}
FREEKASSA_API_KEY=${FREEKASSA_API_KEY}
FREEKASSA_SECRET1=${FREEKASSA_SECRET1}
FREEKASSA_SECRET2=${FREEKASSA_SECRET2}
RESEND_API_KEY=${RESEND_API_KEY}
GOOGLE_IOS_CLIENT_ID=${GOOGLE_IOS_CLIENT_ID}
REALITY_PRIVATE_KEY=${CHAMELEON_WAW_REALITY_PRIVATE_KEY}
REALITY_PUBLIC_KEY=${CHAMELEON_WAW_REALITY_PUBLIC_KEY}
SHADOWSOCKS_PASSWORD=
EOF

echo ">>> ship binary + env + Dockerfile + config (config.production.yaml needs cluster.node_id=waw1)"
RX 'mkdir -p ~/failover'
scp -i "$KEY" /tmp/chameleon-linux "$W:~/failover/chameleon-linux"
scp -i "$KEY" /tmp/chameleon-failover.env "$W:~/failover/chameleon-failover.env"
scp -i "$KEY" Dockerfile.prebuilt "$W:~/failover/"
scp -i "$KEY" config.production.yaml "$W:~/failover/config.production.yaml"
# node_id=waw1 so FindLocalServer loads waw1's Reality key from the DB; ASC path placeholder
RX 'cd ~/failover && sed -i "s/^  node_id: \"\"/  node_id: \"waw1\"/" config.production.yaml; chmod 600 chameleon-failover.env; sudo mkdir -p /etc/chameleon && sudo touch /etc/chameleon/asc-key.p8'

echo ">>> build image + ensure redis + (re)start chameleon-failover"
RX "REDIS_PW='${CHAMELEON_REDIS_PASSWORD}' bash -s" <<'REMOTE'
set -e
cd ~/failover
sudo docker build -f Dockerfile.prebuilt -t chameleon:failover . >/dev/null 2>&1
sudo docker ps --filter name=chameleon-redis -q | grep -q . || \
  sudo docker run -d --name chameleon-redis --network host --restart unless-stopped \
    redis:7-alpine redis-server --requirepass "$REDIS_PW" --maxmemory 128mb --maxmemory-policy allkeys-lru >/dev/null
sudo docker rm -f chameleon-failover 2>/dev/null || true
sudo docker run -d --name chameleon-failover --network host --restart unless-stopped \
  --env-file ~/failover/chameleon-failover.env \
  -v ~/failover/config.production.yaml:/etc/chameleon/config.yaml:ro \
  -v /etc/chameleon/asc-key.p8:/etc/chameleon/asc-key.p8:ro \
  chameleon:failover >/dev/null
sleep 6
echo "health: $(curl -s -m5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/health)"
REMOTE
echo "✅ WAW backend up. Verify: curl https://api.madfrog.online/health (if MSK points to WAW)."
