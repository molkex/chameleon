#!/usr/bin/env bash
# ============================================================
#  Chameleon VPN — One-command installer
#
#  First node (seed):
#    git clone https://github.com/molkex/chameleon.git
#    cd chameleon && sudo ./install.sh
#
#  Additional node (joins cluster):
#    git clone https://github.com/molkex/chameleon.git
#    cd chameleon && sudo ./install.sh --join https://first-node.com --secret CLUSTER_SECRET
#
#  Each node is autonomous: full API + DB + Xray.
#  Nodes sync users between each other every 30 seconds.
#  If one node goes down, others continue working.
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${CYAN}=== $* ===${NC}"; }

# ── Parse args ──
JOIN_URL=""
CLUSTER_SECRET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --join) JOIN_URL="$2"; shift 2 ;;
        --secret) CLUSTER_SECRET="$2"; shift 2 ;;
        *) shift ;;
    esac
done

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

    SERVER_IP=$(curl -sf https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

    cat > .env <<ENVEOF
# Chameleon VPN — auto-generated $(date +%Y-%m-%d)
DATABASE_URL=postgresql://chameleon:${DB_PASS}@postgres:5432/chameleon
REDIS_URL=redis://:${REDIS_PASS}@redis:6379/0
DB_PASSWORD=${DB_PASS}
REDIS_PASSWORD=${REDIS_PASS}

ADMIN_JWT_SECRET=${JWT_SECRET}
ADMIN_SESSION_SECRET=${SESSION_SECRET}
MOBILE_JWT_SECRET=${MOBILE_JWT}

REALITY_PRIVATE_KEY=${REALITY_PRIV}
REALITY_PUBLIC_KEY=${REALITY_PUB}
REALITY_SNIS=ads.x5.ru

ADMIN_USERNAME=admin
ADMIN_PASSWORD=admin

VPN_SERVERS=[{"key":"node1","name":"Server","flag":"","host":"${SERVER_IP}","domain":"${SERVER_IP}"}]

ENVIRONMENT=production
RUST_LOG=info,sqlx=warn
FORCE_HTTPS=0

# Cluster
CLUSTER_SECRET=${CLUSTER_SECRET:-$(openssl rand -hex 32)}
NODE_ID=$(hostname)
CLUSTER_PEERS=${JOIN_URL}
ENVEOF

    # If joining a cluster, register with the seed node
    if [[ -n "$JOIN_URL" ]]; then
        log "Joining cluster: $JOIN_URL"
        CLUSTER_SEC=$(grep CLUSTER_SECRET .env | cut -d= -f2)
        SERVER_IP=$(curl -sf https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
        curl -sf -X POST "${JOIN_URL}/api/v1/cluster/join" \
            -H "Content-Type: application/json" \
            -H "X-Cluster-Secret: ${CLUSTER_SEC}" \
            -d "{\"node_id\": \"$(hostname)\", \"url\": \"http://${SERVER_IP}\", \"ip\": \"${SERVER_IP}\"}" \
            && log "Cluster join: OK" \
            || warn "Cluster join failed — will retry after start"
    fi

    chmod 600 .env
    log "Configuration generated (.env)"
    log "Reality public key: ${REALITY_PUB}"
fi

# Ensure swap exists (Rust compilation needs ~2GB RAM)
if [[ $(swapon --show | wc -l) -eq 0 ]]; then
    log "Creating 2GB swap for compilation..."
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
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
