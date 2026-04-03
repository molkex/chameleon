#!/usr/bin/env bash
# Chameleon VPN — Quick re-deploy (code update + rebuild)
# Usage: ./deploy.sh <server_ip>
#
# Prerequisites: SSH key must be configured for the target server.
#   ssh-copy-id ${SSH_USER:-ubuntu}@<server_ip>
#
# Uploads latest code and rebuilds only changed containers.
set -euo pipefail

SERVER="${1:?Usage: ./deploy.sh <server_ip>}"
SSH_USER="${SSH_USER:-ubuntu}"
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REMOTE_DIR="/home/${SSH_USER}/chameleon/backend"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

SSH_OPTS="-o ConnectTimeout=10 -o BatchMode=yes"

ssh_cmd() {
    ssh $SSH_OPTS "${SSH_USER}@${SERVER}" "$@"
}

scp_cmd() {
    scp $SSH_OPTS "$@"
}

[ -f "$PROJECT_DIR/backend/docker-compose.yml" ] || err "Run from project root"

log "Deploying to ${SERVER}..."

# Upload code
cd "$PROJECT_DIR"
tar czf /tmp/chameleon-deploy.tar.gz \
    --no-xattrs --no-mac-metadata \
    --exclude='.git' \
    --exclude='target' \
    --exclude='node_modules' \
    --exclude='apple' \
    --exclude='backend-legacy-python' \
    --exclude='.DS_Store' \
    -C "$PROJECT_DIR" \
    backend/Cargo.toml backend/Cargo.lock \
    backend/crates \
    backend/migrations \
    backend/Dockerfile \
    backend/docker-compose.yml \
    backend/nginx.conf \
    admin/

scp_cmd /tmp/chameleon-deploy.tar.gz "${SSH_USER}@${SERVER}:/tmp/"

ssh_cmd "cd /home/${SSH_USER}/chameleon && tar xzf /tmp/chameleon-deploy.tar.gz && rm /tmp/chameleon-deploy.tar.gz"

log "Code uploaded. Rebuilding..."

# Rebuild only backend + nginx (keep data containers running)
ssh_cmd "bash -s" <<BUILDEOF
set -e
cd ${REMOTE_DIR}
DOCKER="docker compose"
\$DOCKER version &>/dev/null || DOCKER="sudo docker compose"

\$DOCKER up -d --build --no-deps backend nginx 2>&1
echo "=== Status ==="
\$DOCKER ps
BUILDEOF

# Health check
log "Waiting for health..."
for i in $(seq 1 20); do
    if ssh_cmd "curl -sf http://127.0.0.1/health" >/dev/null 2>&1; then
        log "Deploy successful! http://${SERVER}/admin/app/"
        exit 0
    fi
    sleep 10
done

warn "Backend not healthy yet. Check: ssh ${SSH_USER}@${SERVER} 'cd ${REMOTE_DIR} && docker compose logs backend'"
