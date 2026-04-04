#!/usr/bin/env bash
# ============================================================
#  Chameleon VPN — Node installer
#  Installs Xray VPN node and connects it to the main panel.
#
#  Usage (on a NEW server):
#    curl -sf https://your-panel.com/api/v1/node/install?key=YOUR_KEY | sudo bash
#  Or manually:
#    sudo ./node-install.sh <PANEL_URL> <NODE_API_KEY>
#
#  What it does:
#    1. Installs Docker
#    2. Pulls Xray + config agent
#    3. Registers with the panel
#    4. Sets up auto-sync (config updates every 60s)
#    5. Sets up health reporting
# ============================================================
set -euo pipefail

PANEL_URL="${1:?Usage: ./node-install.sh <PANEL_URL> <NODE_API_KEY>}"
NODE_KEY="${2:?Missing NODE_API_KEY}"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${GREEN}[+]${NC} $*"; }
err() { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Run as root: sudo ./node-install.sh ..."

# ── 1. Install Docker ──
if ! command -v docker &>/dev/null; then
    log "Installing Docker..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
log "Docker: $(docker --version)"

# ── 2. Create node directory ──
NODE_DIR="/opt/chameleon-node"
mkdir -p "$NODE_DIR"
cd "$NODE_DIR"

# ── 3. Register with panel ──
log "Registering with panel..."
SERVER_IP=$(curl -sf https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

REG_RESPONSE=$(curl -sf -X POST "${PANEL_URL}/api/v1/node/register" \
    -H "Content-Type: application/json" \
    -H "X-Node-Key: ${NODE_KEY}" \
    -d "{\"ip\": \"${SERVER_IP}\", \"hostname\": \"$(hostname)\"}" 2>&1) || err "Failed to register with panel"

NODE_ID=$(echo "$REG_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('node_id',''))" 2>/dev/null)
[[ -n "$NODE_ID" ]] || err "Registration failed: $REG_RESPONSE"
log "Registered as node: $NODE_ID"

# ── 4. Create sync script ──
cat > sync.sh << 'SYNCEOF'
#!/usr/bin/env bash
# Pull latest Xray config from panel and reload
set -euo pipefail

PANEL_URL="__PANEL_URL__"
NODE_KEY="__NODE_KEY__"
CONFIG_DIR="/opt/chameleon-node/xray"

mkdir -p "$CONFIG_DIR"

# Fetch config
RESPONSE=$(curl -sf "${PANEL_URL}/api/v1/node/config" \
    -H "X-Node-Key: ${NODE_KEY}" 2>/dev/null)

if [[ -n "$RESPONSE" ]]; then
    echo "$RESPONSE" > "${CONFIG_DIR}/config.json.new"

    # Only reload if config changed
    if ! diff -q "${CONFIG_DIR}/config.json" "${CONFIG_DIR}/config.json.new" &>/dev/null; then
        mv "${CONFIG_DIR}/config.json.new" "${CONFIG_DIR}/config.json"
        docker restart xray-node 2>/dev/null || true
        echo "[$(date)] Config updated and Xray reloaded"
    else
        rm "${CONFIG_DIR}/config.json.new"
    fi
fi

# Report health
curl -sf -X POST "${PANEL_URL}/api/v1/node/health" \
    -H "X-Node-Key: ${NODE_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"status\": \"ok\", \"uptime\": $(cat /proc/uptime | cut -d' ' -f1), \"load\": $(cat /proc/loadavg | cut -d' ' -f1)}" \
    2>/dev/null || true
SYNCEOF

sed -i "s|__PANEL_URL__|${PANEL_URL}|g; s|__NODE_KEY__|${NODE_KEY}|g" sync.sh
chmod +x sync.sh

# ── 5. Create docker-compose for the node ──
cat > docker-compose.yml << 'DCEOF'
services:
  xray-node:
    image: teddysun/xray:1.8.24
    container_name: xray-node
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./xray:/etc/xray:ro
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
DCEOF

# ── 6. Initial config pull ──
log "Pulling initial config..."
bash sync.sh

# ── 7. Start Xray ──
docker compose up -d
log "Xray node started"

# ── 8. Setup cron for auto-sync (every 60s) ──
CRON_LINE="* * * * * /opt/chameleon-node/sync.sh >> /var/log/chameleon-node.log 2>&1"
(crontab -l 2>/dev/null | grep -v "chameleon-node"; echo "$CRON_LINE") | crontab -
log "Auto-sync configured (every 60s)"

# ── Done ──
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Chameleon Node installed!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "  Node ID:   ${CYAN}${NODE_ID}${NC}"
echo -e "  Server IP: ${CYAN}${SERVER_IP}${NC}"
echo -e "  Panel:     ${CYAN}${PANEL_URL}${NC}"
echo ""
echo -e "  Logs:  ${CYAN}tail -f /var/log/chameleon-node.log${NC}"
echo -e "  Xray:  ${CYAN}docker logs xray-node${NC}"
echo ""
