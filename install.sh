#!/usr/bin/env bash
# ============================================================
#  Chameleon VPN — One-command installer
#  Usage: git clone https://github.com/molkex/chameleon.git
#         cd chameleon && sudo ./install.sh
#
#  Builds everything from source — no external registry needed.
#  First install takes ~10 minutes (Rust compilation).
#  Subsequent rebuilds are faster due to Docker layer caching.
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${CYAN}=== $* ===${NC}"; }

# ── Preflight ──
[[ $EUID -eq 0 ]] || err "Run as root: sudo ./install.sh"
[[ -f docker-compose.yml ]] || err "Run from chameleon project root"

START_TIME=$(date +%s)

step "1/5 Installing Docker"
if command -v docker &>/dev/null; then
    log "Docker already installed: $(docker --version)"
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    log "Docker installed: $(docker --version)"
fi

step "2/5 Generating configuration"
if [[ -f .env ]]; then
    warn ".env already exists — skipping generation"
else
    DB_PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
    REDIS_PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
    JWT_SECRET=$(openssl rand -hex 32)
    SESSION_SECRET=$(openssl rand -hex 32)
    MOBILE_JWT=$(openssl rand -hex 32)

    # Generate Xray Reality keys
    log "Generating Reality x25519 keys..."
    docker pull -q teddysun/xray:1.8.24 >/dev/null 2>&1
    KEYS=$(docker run --rm teddysun/xray:1.8.24 xray x25519 2>/dev/null)
    REALITY_PRIV=$(echo "$KEYS" | grep "Private" | awk '{print $NF}')
    REALITY_PUB=$(echo "$KEYS" | grep "Public" | awk '{print $NF}')

    ADMIN_PASS=$(openssl rand -base64 16)

    cat > .env <<ENVEOF
# Chameleon VPN — auto-generated $(date +%Y-%m-%d)
DATABASE_URL=postgresql://chameleon:${DB_PASS}@postgres:5432/chameleon
REDIS_URL=redis://:${REDIS_PASS}@redis:6379/0
DB_PASSWORD=${DB_PASS}
REDIS_PASSWORD=${REDIS_PASS}

ADMIN_USERNAME=admin
ADMIN_PASSWORD=${ADMIN_PASS}

ADMIN_JWT_SECRET=${JWT_SECRET}
ADMIN_SESSION_SECRET=${SESSION_SECRET}
MOBILE_JWT_SECRET=${MOBILE_JWT}

REALITY_PRIVATE_KEY=${REALITY_PRIV}
REALITY_PUBLIC_KEY=${REALITY_PUB}
REALITY_SNIS=ads.x5.ru

ENVIRONMENT=production
RUST_LOG=info,sqlx=warn
FORCE_HTTPS=0
ENVEOF

    chmod 600 .env
    log "Configuration generated (.env)"
    log "Reality public key: ${REALITY_PUB}"
fi

step "3/5 Building from source (first time takes ~10 min)"
docker compose build --parallel 2>&1 | tail -5
log "Build complete"

step "4/5 Starting services"
docker compose up -d
log "Services started"

step "5/5 Waiting for backend"
for i in $(seq 1 60); do
    if curl -sf http://127.0.0.1/health >/dev/null 2>&1; then
        break
    fi
    if [[ $i -eq 60 ]]; then
        warn "Backend not healthy yet — check: docker compose logs backend"
    fi
    sleep 5
done

# ── Done ──
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
SERVER_IP=$(curl -sf https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Chameleon VPN installed!${NC}"
echo -e "${GREEN}  Time: ${ELAPSED} seconds${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "  Admin:    ${CYAN}http://${SERVER_IP}/admin/app/${NC}"
echo -e "  API:      ${CYAN}http://${SERVER_IP}/api/v1/${NC}"
echo -e "  Login:    admin / ${ADMIN_PASS:-$(grep ADMIN_PASSWORD .env 2>/dev/null | cut -d= -f2)}"
echo ""
echo -e "  Update:   ${CYAN}sudo ./update.sh${NC}"
echo -e "  Logs:     ${CYAN}docker compose logs -f${NC}"
echo -e "  Status:   ${CYAN}docker compose ps${NC}"
echo ""
