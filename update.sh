#!/usr/bin/env bash
# ============================================================
#  Chameleon VPN — Quick update
#  Pulls latest code, rebuilds changed containers
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${GREEN}[+]${NC} $*"; }

cd "$(dirname "$0")"
[[ -f docker-compose.yml ]] || { echo "Run from chameleon root"; exit 1; }

echo -e "${CYAN}Updating Chameleon VPN...${NC}"

# Pull latest code
if [[ -d .git ]]; then
    git pull --ff-only 2>/dev/null && log "Code updated" || log "Code already up to date"
fi

# Rebuild changed images and restart
docker compose up -d --build --remove-orphans
log "Services rebuilt and restarted"

# Quick health check
for i in $(seq 1 24); do
    if curl -sf http://127.0.0.1/health >/dev/null 2>&1; then
        log "Backend healthy"
        break
    fi
    [[ $i -eq 24 ]] && echo "Backend starting..."
    sleep 5
done

echo ""
docker compose ps
echo ""
log "Update complete!"
