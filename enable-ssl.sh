#!/usr/bin/env bash
# Enable HTTPS for Chameleon VPN using Let's Encrypt
set -euo pipefail

DOMAIN="${1:-razblokirator.ru}"
EMAIL="${2:-admin@$DOMAIN}"

GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[+]${NC} $*"; }

cd "$(dirname "$0")"
[[ -f docker-compose.yml ]] || { echo "Run from chameleon root"; exit 1; }

# Create certbot webroot
docker volume create certbot-webroot 2>/dev/null || true
docker volume create certbot-certs 2>/dev/null || true

# Ensure nginx is running with HTTP (for ACME challenge)
log "Restarting nginx for ACME challenge..."
docker compose up -d nginx

# Get certificate using standalone (stop nginx briefly)
log "Obtaining SSL certificate for $DOMAIN..."
docker compose stop nginx

docker run --rm \
  -p 80:80 \
  -v certbot-certs:/etc/letsencrypt \
  certbot/certbot certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    --email "$EMAIL" \
    -d "$DOMAIN"

# Copy certs to the volume in the format nginx expects
docker run --rm \
  -v certbot-certs:/certs \
  alpine sh -c "
    cp /certs/live/$DOMAIN/fullchain.pem /certs/fullchain.pem
    cp /certs/live/$DOMAIN/privkey.pem /certs/privkey.pem
  "

# Switch to SSL config
log "Switching to HTTPS nginx config..."
cp backend/nginx-ssl.conf backend/nginx.conf

# Restart everything
docker compose up -d nginx
log "HTTPS enabled! https://$DOMAIN"

# Set up auto-renewal cron
(crontab -l 2>/dev/null | grep -v certbot; echo "0 3 1 * * cd $(pwd) && docker run --rm -v certbot-certs:/etc/letsencrypt certbot/certbot renew --quiet && docker compose restart nginx") | crontab -
log "Auto-renewal cron added (monthly)"
