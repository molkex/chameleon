#!/usr/bin/env bash
# Chameleon VPN — One-command server setup
# Usage: ./setup.sh <server_ip>
#
# Prerequisites: SSH key must be configured for the target server.
#   ssh-copy-id ${SSH_USER:-ubuntu}@<server_ip>
#
# For initial setup when only password auth is available, set DEPLOY_PASSWORD:
#   DEPLOY_PASSWORD="xxx" ./setup.sh <server_ip>
# The password is passed via env var (not CLI arg) to avoid exposure in ps aux.
#
# Installs Docker, deploys backend + admin + xray + postgres + redis.
set -euo pipefail

SERVER="${1:?Usage: ./setup.sh <server_ip>}"
SSH_USER="${SSH_USER:-ubuntu}"
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REMOTE_DIR="/home/${SSH_USER}/chameleon/backend"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

# SSH transport: use sshpass only when DEPLOY_PASSWORD is set (initial setup).
# StrictHostKeyChecking=accept-new accepts new hosts but rejects changed keys (MITM protection).
if [ -n "${DEPLOY_PASSWORD:-}" ]; then
    command -v sshpass >/dev/null || err "sshpass required when using DEPLOY_PASSWORD. brew install sshpass / apt install sshpass"
    SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
    ssh_cmd() {
        sshpass -e ssh $SSH_OPTS "${SSH_USER}@${SERVER}" "$@"
    }
    scp_cmd() {
        sshpass -e scp $SSH_OPTS "$@"
    }
    export SSHPASS="$DEPLOY_PASSWORD"
    warn "Using password auth via DEPLOY_PASSWORD. Set up SSH keys after initial setup."
else
    SSH_OPTS="-o ConnectTimeout=10 -o BatchMode=yes"
    ssh_cmd() {
        ssh $SSH_OPTS "${SSH_USER}@${SERVER}" "$@"
    }
    scp_cmd() {
        scp $SSH_OPTS "$@"
    }
fi

# Preflight checks
[ -f "$PROJECT_DIR/backend/docker-compose.yml" ] || err "Run from project root or infrastructure/deploy/"
[ -f "$PROJECT_DIR/backend/.env" ] || err "backend/.env not found. Copy .env.example and fill in values first."

log "Testing SSH connection to ${SERVER}..."
ssh_cmd 'echo ok' >/dev/null || err "SSH failed. Check credentials or SSH key setup."

# ── Step 1: Install Docker ──
log "Installing Docker on ${SERVER}..."
ssh_cmd 'bash -s' <<'DOCKER_EOF'
set -e
if command -v docker &>/dev/null; then
    echo "Docker already installed: $(docker --version)"
else
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker "$USER"
    echo "Docker installed: $(docker --version)"
fi
DOCKER_EOF

# ── Step 2: Create project directory ──
log "Creating project directory..."
ssh_cmd "mkdir -p ${REMOTE_DIR}"

# ── Step 3: Upload project files ──
log "Uploading project files..."
cd "$PROJECT_DIR"

# Create tarball excluding unnecessary files
tar czf /tmp/chameleon-deploy.tar.gz \
    --no-xattrs --no-mac-metadata \
    --exclude='.git' \
    --exclude='target' \
    --exclude='node_modules' \
    --exclude='.next' \
    --exclude='apple' \
    --exclude='backend-legacy-python' \
    --exclude='.DS_Store' \
    --exclude='*.xcodeproj' \
    --exclude='*.xcworkspace' \
    -C "$PROJECT_DIR" \
    backend/Cargo.toml backend/Cargo.lock \
    backend/crates \
    backend/migrations \
    backend/Dockerfile \
    backend/docker-compose.yml \
    backend/nginx.conf \
    backend/.env \
    admin/

scp_cmd /tmp/chameleon-deploy.tar.gz "${SSH_USER}@${SERVER}:/tmp/"

ssh_cmd "cd /home/${SSH_USER}/chameleon && tar xzf /tmp/chameleon-deploy.tar.gz && rm /tmp/chameleon-deploy.tar.gz"

log "Files uploaded."

# ── Step 4: Build and start ──
log "Building and starting services (this takes 5-10 minutes on first run)..."
ssh_cmd "bash -s" <<BUILDEOF
set -e
cd ${REMOTE_DIR}

# Ensure docker compose works (might need newgrp or sudo)
if ! docker compose version &>/dev/null; then
    echo "Using sudo for docker..."
    DOCKER="sudo docker compose"
else
    DOCKER="docker compose"
fi

# Pull base images first
\$DOCKER pull postgres:16-alpine redis:7-alpine ghcr.io/xtls/xray-core:v26.3.27 || true

# Build and start
\$DOCKER up -d --build 2>&1

echo "=== Services ==="
\$DOCKER ps
BUILDEOF

# ── Step 5: Wait for healthy backend ──
log "Waiting for backend to become healthy..."
for i in $(seq 1 30); do
    if ssh_cmd "curl -sf http://127.0.0.1/health" >/dev/null 2>&1; then
        log "Backend is healthy!"
        break
    fi
    if [ "$i" -eq 30 ]; then
        warn "Backend not healthy after 5 minutes. Check logs: docker compose logs backend"
    fi
    sleep 10
done

# ── Done ──
echo ""
log "========================================="
log "  Chameleon VPN deployed to ${SERVER}"
log "========================================="
log "  Admin:  http://${SERVER}/admin/app/"
log "  API:    http://${SERVER}/api/v1/"
log "  Health: http://${SERVER}/health"
log ""
log "  SSH:    ssh ${SSH_USER}@${SERVER}"
log "  Logs:   cd ${REMOTE_DIR} && docker compose logs -f"
log "========================================="
