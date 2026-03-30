#!/usr/bin/env bash
# ============================================================
#  Chameleon VPN — Quick update
#  Pulls latest code + images, restarts changed containers
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${GREEN}[✓]${NC} $*"; }

cd "$(dirname "$0")"
[[ -f docker-compose.yml ]] || { echo "Run from chameleon root"; exit 1; }

echo -e "${CYAN}Updating Chameleon VPN...${NC}"

# Pull latest code
if [[ -d .git ]]; then
    git pull --ff-only 2>/dev/null && log "Code updated" || log "Code already up to date"
fi

# Pull latest images
docker compose pull -q
log "Images pulled"

# Restart with new images
docker compose up -d --remove-orphans
log "Services restarted"

# Quick health check
for i in $(seq 1 12); do
    if curl -sf http://127.0.0.1/health >/dev/null 2>&1; then
        log "Backend healthy"
        break
    fi
    [[ $i -eq 12 ]] && echo "Backend starting..."
    sleep 5
done

echo ""
docker compose ps
echo ""
log "Update complete!"
