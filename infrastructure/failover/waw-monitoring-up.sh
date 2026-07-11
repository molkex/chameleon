#!/usr/bin/env bash
# ============================================================
#  Bring up the MONITORING stack (node-exporter + Prometheus + Grafana) on WAW.
# ============================================================
# WHY: pre-2026-07-01 Grafana ran ONLY on NL; after the 2026-06-29 NL→WAW
# failover NL is a stopped replica, so grafana.madfrog.online (CF origin=NL)
# timed out. This reproduces the MON-04 stack on WAW — the SAME prometheus.yml
# + grafana provisioning/dashboards from backend/ — all host-net, bound to
# 127.0.0.1, fronted by chameleon-nginx's grafana.madfrog.online vhost.
# Idempotent. Run from repo root with ~/.secrets.env present.
#   ./infrastructure/failover/waw-monitoring-up.sh
#
# CF flip (grafana.madfrog.online → WAW) is guarded behind FLIP_CF=1.
set -euo pipefail
cd "$(dirname "$0")/../../backend"
# shellcheck source=/dev/null
source ~/.secrets.env 2>/dev/null || true
W=debian@217.182.74.70; KEY=~/.ssh/claude-code-ssh-key; WAW_IP=217.182.74.70
RX(){ ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "$W" "$@"; }
# COPYFILE_DISABLE=1 keeps macOS from injecting ._* AppleDouble files that
# Grafana's provisioner would then fail to parse as YAML.
TAR(){ COPYFILE_DISABLE=1 tar czf - "$@"; }

echo ">>> ship prometheus.yml (node label → waw) + grafana provisioning/dashboards to WAW:~/monitoring"
RX 'mkdir -p ~/monitoring/grafana/provisioning ~/monitoring/grafana/dashboards'
sed "s/node: .nl./node: 'waw'/" prometheus.yml | RX 'cat > ~/monitoring/prometheus.yml'
TAR grafana/provisioning | RX 'tar xzf - -C ~/monitoring/grafana --strip-components=1'
TAR -C grafana/dashboards . | RX 'tar xzf - -C ~/monitoring/grafana/dashboards'
RX 'find ~/monitoring -name "._*" -delete'

echo ">>> node-exporter (:9100 loopback, host metrics)"
RX 'sudo docker rm -f chameleon-node-exporter 2>/dev/null || true; \
  sudo docker run -d --name chameleon-node-exporter --restart unless-stopped --network host --pid host \
    --security-opt no-new-privileges:true \
    -v /proc:/host/proc:ro -v /sys:/host/sys:ro -v /:/host:ro,rslave \
    prom/node-exporter:v1.8.2 \
    --path.rootfs=/host --web.listen-address=127.0.0.1:9100 \
    "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)(\$|/)" \
    --no-collector.ipvs >/dev/null'

echo ">>> Prometheus (:9091 loopback, 7d retention)"
RX 'sudo docker volume create chameleon-prometheus-data >/dev/null; \
  sudo docker rm -f chameleon-prometheus 2>/dev/null || true; \
  sudo docker run -d --name chameleon-prometheus --restart unless-stopped --network host \
    --security-opt no-new-privileges:true \
    -v ~/monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
    -v chameleon-prometheus-data:/prometheus \
    prom/prometheus:v2.55.1 \
    --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus \
    --storage.tsdb.retention.time=7d --web.listen-address=127.0.0.1:9091 \
    --web.external-url=http://127.0.0.1:9091 >/dev/null'

echo ">>> Grafana (:3000 loopback; admin pw from CHAMELEON_GRAFANA_PASSWORD)"
RX "sudo docker volume create chameleon-grafana-data >/dev/null; \
  sudo docker rm -f chameleon-grafana 2>/dev/null || true; \
  sudo docker run -d --name chameleon-grafana --restart unless-stopped --network host \
    --security-opt no-new-privileges:true \
    -e GF_SECURITY_ADMIN_PASSWORD='${CHAMELEON_GRAFANA_PASSWORD}' -e GF_SECURITY_ADMIN_USER=admin \
    -e GF_SERVER_HTTP_ADDR=127.0.0.1 -e GF_SERVER_HTTP_PORT=3000 \
    -e GF_SERVER_DOMAIN=grafana.madfrog.online -e GF_SERVER_ROOT_URL=https://grafana.madfrog.online/ \
    -e GF_ANALYTICS_REPORTING_ENABLED=false -e GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    -e GF_USERS_ALLOW_SIGN_UP=false -e GF_AUTH_ANONYMOUS_ENABLED=false \
    -v ~/monitoring/grafana/provisioning:/etc/grafana/provisioning:ro \
    -v ~/monitoring/grafana/dashboards:/var/lib/grafana/dashboards:ro \
    -v chameleon-grafana-data:/var/lib/grafana \
    grafana/grafana-oss:11.3.1 >/dev/null"

echo ">>> verify (give grafana a few seconds)"
RX 'for i in $(seq 1 6); do sleep 2; done; \
  echo "  grafana health: $(curl -sS -m8 http://127.0.0.1:3000/api/health | tr -d "\n ")"; \
  echo "  prom targets: $(curl -sS -m8 "http://127.0.0.1:9091/api/v1/targets?state=active" | python3 -c "import sys,json;print(\", \".join(t[\"labels\"][\"job\"]+\"=\"+t[\"health\"] for t in json.load(sys.stdin)[\"data\"][\"activeTargets\"]))")"; \
  echo "  via nginx: grafana.madfrog.online → $(curl -sS -o /dev/null -w "%{http_code}" -m8 -H "Host: grafana.madfrog.online" http://127.0.0.1/)"'

if [ "${FLIP_CF:-0}" = "1" ] && [ -n "${CLOUDFLARE_EMAIL:-}" ] && [ -n "${CLOUDFLARE_API_KEY:-}" ]; then
  echo ">>> FLIP_CF=1 — grafana.madfrog.online → $WAW_IP (proxied)"
  CFAPI="https://api.cloudflare.com/client/v4"
  Z=$(curl -sS -H "X-Auth-Email: $CLOUDFLARE_EMAIL" -H "X-Auth-Key: $CLOUDFLARE_API_KEY" "$CFAPI/zones?name=madfrog.online" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"][0]["id"])')
  id=$(curl -sS -H "X-Auth-Email: $CLOUDFLARE_EMAIL" -H "X-Auth-Key: $CLOUDFLARE_API_KEY" "$CFAPI/zones/$Z/dns_records?type=A&name=grafana.madfrog.online" | python3 -c 'import sys,json;r=json.load(sys.stdin)["result"];print(r[0]["id"] if r else "")')
  [ -n "$id" ] && curl -sS -X PATCH -H "X-Auth-Email: $CLOUDFLARE_EMAIL" -H "X-Auth-Key: $CLOUDFLARE_API_KEY" -H "Content-Type: application/json" \
    "$CFAPI/zones/$Z/dns_records/$id" -d "{\"content\":\"$WAW_IP\"}" >/dev/null && echo "  flipped"
else
  echo ">>> (CF grafana record NOT flipped — re-run with FLIP_CF=1)"
fi
echo "✅ WAW monitoring up. Public: https://grafana.madfrog.online/"
