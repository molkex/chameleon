#!/usr/bin/env bash
# ============================================================
#  Bring up / refresh the WEB layer (landing + admin SPA + /api reverse proxy)
#  on WAW — makes the public site independent of NL (ADR 0013 P1/P4).
# ============================================================
# WHY: pre-2026-07-01 the apex madfrog.online (landing + admin SPA) was served
# ONLY by NL's chameleon-nginx. After the 2026-06-29 NL→WAW failover NL is a
# stopped replica, so Cloudflare (origin=NL) returned 522 and the admin UI was
# unreachable. This reproduces that web layer on WAW: the SAME clients/admin
# image content + backend/nginx.conf, proxying /api,/health,/sub → 127.0.0.1:8000
# (the WAW backend). Idempotent — safe to re-run to ship a fresh SPA build.
#
# Run from the repo root with ~/.secrets.env present.
#   ./infrastructure/failover/waw-web-up.sh
#
# The Cloudflare apex origin flip (madfrog.online + www A-record → WAW) is a
# SEPARATE, guarded step at the end (only runs with FLIP_CF=1 + CF creds) so a
# plain asset refresh never touches DNS. See docs/decisions/0013.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=/dev/null
source ~/.secrets.env 2>/dev/null || true
W=debian@217.182.74.70; KEY=~/.ssh/claude-code-ssh-key; WAW_IP=217.182.74.70
RX(){ ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "$W" "$@"; }

echo ">>> build admin SPA (base /admin/app/, API relative /api/v1)"
( cd clients/admin && npm ci --silent && npm run build >/dev/null )

echo ">>> ship SPA + landing + nginx.conf to WAW:~/chameleon-web (tar-over-ssh; no remote rsync)"
RX 'mkdir -p ~/chameleon-web/admin ~/chameleon-web/landing'
tar czf - -C clients/admin/dist . | RX 'rm -rf ~/chameleon-web/admin/* && tar xzf - -C ~/chameleon-web/admin'
tar czf - -C backend/landing . | RX 'rm -rf ~/chameleon-web/landing/* && tar xzf - -C ~/chameleon-web/landing'
tar czf - -C backend nginx.conf | RX 'tar xzf - -C ~/chameleon-web'

echo ">>> (re)start chameleon-nginx container (host net :80 → 127.0.0.1:8000)"
RX 'sudo docker pull nginx:1.27-alpine >/dev/null; sudo docker rm -f chameleon-nginx 2>/dev/null || true; \
  sudo docker run -d --name chameleon-nginx --restart unless-stopped --network host \
    --security-opt no-new-privileges:true \
    -v ~/chameleon-web/nginx.conf:/etc/nginx/conf.d/default.conf:ro \
    -v ~/chameleon-web/admin:/usr/share/nginx/html/admin:ro \
    -v ~/chameleon-web/landing:/usr/share/nginx/html/landing:ro \
    nginx:1.27-alpine >/dev/null; \
  sudo docker exec chameleon-nginx nginx -t'

echo ">>> ufw: allow :80 from Cloudflare IPv4 ranges only (origin not exposed wide)"
RX 'for r in 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22; do \
    sudo ufw allow from $r to any port 80 proto tcp comment "Cloudflare origin (madfrog.online web)" >/dev/null; done'

echo ">>> verify locally on WAW (Host: madfrog.online)"
RX 'b(){ curl -sS -o /dev/null -w "%{http_code}" --max-time 8 -H "Host: madfrog.online" -H "X-Forwarded-Proto: https" "$1"; }; \
  echo "  /health=$(b http://127.0.0.1/health) /=$(b http://127.0.0.1/) /admin/app/=$(b http://127.0.0.1/admin/app/) /api/v1/mobile/healthcheck=$(b http://127.0.0.1/api/v1/mobile/healthcheck)"'

# ── Cloudflare apex origin flip (guarded) ────────────────────────────────────
if [ "${FLIP_CF:-0}" = "1" ] && [ -n "${CLOUDFLARE_EMAIL:-}" ] && [ -n "${CLOUDFLARE_API_KEY:-}" ]; then
  echo ">>> FLIP_CF=1 — pointing madfrog.online + www A-records → $WAW_IP (proxied)"
  CFAPI="https://api.cloudflare.com/client/v4"
  Z=$(curl -sS -H "X-Auth-Email: $CLOUDFLARE_EMAIL" -H "X-Auth-Key: $CLOUDFLARE_API_KEY" "$CFAPI/zones?name=madfrog.online" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"][0]["id"])')
  for nm in madfrog.online www.madfrog.online; do
    id=$(curl -sS -H "X-Auth-Email: $CLOUDFLARE_EMAIL" -H "X-Auth-Key: $CLOUDFLARE_API_KEY" "$CFAPI/zones/$Z/dns_records?type=A&name=$nm" | python3 -c 'import sys,json;r=json.load(sys.stdin)["result"];print(r[0]["id"] if r else "")')
    [ -n "$id" ] && curl -sS -X PATCH -H "X-Auth-Email: $CLOUDFLARE_EMAIL" -H "X-Auth-Key: $CLOUDFLARE_API_KEY" -H "Content-Type: application/json" \
      "$CFAPI/zones/$Z/dns_records/$id" -d "{\"content\":\"$WAW_IP\"}" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print('  $nm ->',d['result']['content']) if d.get('success') else print('  $nm FAIL',d.get('errors'))"
  done
else
  echo ">>> (CF apex origin NOT flipped — re-run with FLIP_CF=1 to point madfrog.online+www → WAW)"
fi

echo "✅ WAW web layer up. Public check: curl -I https://madfrog.online/admin/app/"
