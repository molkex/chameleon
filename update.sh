#!/usr/bin/env bash
# ============================================================
#  Chameleon VPN — Quick update
#  Downloads pre-built binaries, rebuilds containers
#  Usage: sudo ./update.sh [--build]
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

cd "$(dirname "$0")"
[[ -f docker-compose.yml ]] || { echo "Run from chameleon root"; exit 1; }

FORCE_BUILD=false
[[ "${1:-}" == "--build" ]] && FORCE_BUILD=true

START_TIME=$(date +%s)
echo -e "${CYAN}Updating Chameleon VPN...${NC}"

# Pull latest code
if [[ -d .git ]]; then
    git pull --ff-only 2>/dev/null && log "Code updated" || log "Code already up to date"
fi

# Download pre-built binaries
GITHUB_REPO="molkex/chameleon"
RELEASE_URL="https://github.com/${GITHUB_REPO}/releases/download/latest"
PREBUILT=false

if [[ "$FORCE_BUILD" == "false" && "$(dpkg --print-architecture 2>/dev/null)" == "amd64" ]]; then
    if curl -sfL --connect-timeout 15 "${RELEASE_URL}/chameleon-backend-linux-amd64.tar.gz" -o /tmp/chameleon-backend.tar.gz 2>/dev/null; then
        mkdir -p backend/bin
        tar xzf /tmp/chameleon-backend.tar.gz -C backend/bin/
        rm -f /tmp/chameleon-backend.tar.gz
        PREBUILT=true
        log "Backend binary downloaded"
    fi
    if curl -sfL --connect-timeout 15 "${RELEASE_URL}/chameleon-admin-dist.tar.gz" -o /tmp/chameleon-admin.tar.gz 2>/dev/null; then
        mkdir -p admin/dist
        tar xzf /tmp/chameleon-admin.tar.gz -C admin/dist/
        rm -f /tmp/chameleon-admin.tar.gz
        log "Admin panel downloaded"
    fi
fi

# Rebuild and restart
if [[ "$PREBUILT" == "true" ]]; then
    log "Rebuilding with pre-built binaries..."
    docker build -f backend/Dockerfile.prebuilt -t chameleon-backend backend/ 2>&1 | tail -3
    docker build -f admin/Dockerfile.prebuilt -t chameleon-nginx admin/ 2>&1 | tail -3
    docker compose up -d --remove-orphans
else
    log "Rebuilding from source..."
    docker compose up -d --build --remove-orphans
fi
log "Services restarted"

# Quick health check
for i in $(seq 1 24); do
    if curl -sf http://127.0.0.1/health >/dev/null 2>&1; then
        log "Backend healthy"
        break
    fi
    [[ $i -eq 24 ]] && warn "Backend starting..."
    sleep 5
done

END_TIME=$(date +%s)
echo ""
docker compose ps
echo ""
log "Update complete! ($(( END_TIME - START_TIME ))s)"
