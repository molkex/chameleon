#!/bin/bash
# Chameleon VPN — Deploy Go backend to any node
# Usage: ./deploy.sh <node> [--with-singbox]
#   node: nl, all
#   --with-singbox: also restart singbox (causes brief VPN drop!)
#
# sing-box runs OUTSIDE docker-compose as a standalone container.
# Normal deploys NEVER touch singbox — VPN connections survive.
set -euo pipefail

NODE="${1:-}"
WITH_SINGBOX=0
for arg in "$@"; do
    [ "$arg" = "--with-singbox" ] && WITH_SINGBOX=1
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Node registry ─────────────────────────────────────────────────────────
get_node_config() {
    case "$1" in
        de)
            echo "DE retired 2026-05-25 — refusing to deploy"; exit 1
            ;;
        nl)
            # ⚠️ 2026-06-29 FAILOVER: NL is now a streaming REPLICA; WAW (OVH Warsaw) is the
            # PRIMARY backend+DB. Deploying chameleon to NL would start its backend against a
            # read-only replica (crash-loop) — or split-brain if NL's DB is ever promoted.
            # The current primary is whatever MSK points to: `infrastructure/failover/failover.sh status`.
            # To make NL primary again, run failover.sh first. Override only if you know what you're doing.
            if [ "${ALLOW_NL_DEPLOY:-0}" != "1" ]; then
                echo "REFUSING: NL is a REPLICA since the 2026-06-29 failover (primary = WAW)."
                echo "  See ADR 0013 / infrastructure/failover/. To force: ALLOW_NL_DEPLOY=1 ./deploy.sh nl"
                exit 1
            fi
            NODE_SSH="root@147.45.252.234"
            NODE_DIR="/opt/chameleon"
            NODE_NODE_ID="nl2-1"
            NODE_SNI="ads.adfox.ru"
            NODE_PREBUILT=1  # 2GB RAM — can't compile Go in Docker
            ;;
        all)
            "$0" nl "${@:2}"
            exit 0
            ;;
        *)
            echo "Usage: $0 <nl|all> [--with-singbox]"
            exit 1
            ;;
    esac
}

get_node_config "$NODE"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Deploying Chameleon to ${NODE} (${NODE_SSH})"
[ "$WITH_SINGBOX" -eq 1 ] && echo "║  ⚠  --with-singbox: will restart VPN!"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Load secrets ───────────────────────────────────────────────────────────
source ~/.secrets.env

# ── Cross-compile if needed ────────────────────────────────────────────────
if [ "$NODE_PREBUILT" -eq 1 ]; then
    echo ">>> Cross-compiling Go binary for linux/amd64..."
    cd "$SCRIPT_DIR"
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
        -trimpath -ldflags="-s -w" \
        -o chameleon-linux ./cmd/chameleon
    echo ">>> Binary ready: $(ls -lh chameleon-linux | awk '{print $5}')"
    cd "$PROJECT_DIR"
fi

# ── Build admin SPA locally ────────────────────────────────────────────────
# Same reason as the Go cross-compile above: the NL box has ~2GB RAM and
# running npm/vite there OOMs the host, and the OOM-killer restarts singbox
# → VPN drops for everyone (2026-05-29 incident:
# docs/incidents/2026-05-29-nginx-stale-spa-oom.md). So we build the SPA HERE
# and ship the prebuilt dist; the remote builds a trivial COPY-only nginx
# image (Dockerfile.prebuilt-spa) instead of running the multi-stage build.
echo ">>> Building admin SPA locally (vite)..."
(
    cd "${PROJECT_DIR}/clients/admin"
    [ -d node_modules ] || npm ci --no-audit --no-fund
    npm run build
)
echo ">>> SPA dist ready: $(du -sh "${PROJECT_DIR}/clients/admin/dist" 2>/dev/null | awk '{print $1}')"

# ── Migrate legacy directory name (one-time) ───────────────────────────────
# Repo renamed backend-go/ → backend/ (2026-04-23). On first deploy after this
# change, move the existing dir on the server so rsync --delete does not nuke
# config.yaml, .env, and other non-tracked state.
ssh "${NODE_SSH}" "test -d ${NODE_DIR}/backend-go && test ! -d ${NODE_DIR}/backend && mv ${NODE_DIR}/backend-go ${NODE_DIR}/backend && echo 'migrated backend-go → backend' || true"

# ── Sync files ─────────────────────────────────────────────────────────────
echo ">>> Syncing files to ${NODE_SSH}:${NODE_DIR}..."
rsync -avz --delete \
    --exclude='.git' \
    --exclude='backend/chameleon' \
    --exclude='backend/ascinit' \
    --exclude='.env' \
    --exclude='backend/.env' \
    --exclude='backend/config.yaml' \
    --exclude='node_modules' \
    --exclude='target' \
    --exclude='ss-ws' \
    -e ssh \
    "${PROJECT_DIR}/" \
    "${NODE_SSH}:${NODE_DIR}/"

# ── ASC API key (BE-01b) ───────────────────────────────────────────────────
# Provision the App Store Connect .p8 file at /etc/chameleon/asc-key.p8
# on the remote so docker-compose's bind mount has something to read.
# Skip cleanly if ASC_KEY_PATH isn't set locally — the chameleon side
# detects missing creds and renders an "ASC not configured" placeholder.
if [ -n "${ASC_KEY_PATH:-}" ] && [ -f "${ASC_KEY_PATH}" ]; then
    echo ">>> Pushing ASC .p8 key to ${NODE_SSH}:/etc/chameleon/asc-key.p8 ..."
    ssh "${NODE_SSH}" "mkdir -p /etc/chameleon && touch /etc/chameleon/asc-key.p8 && chmod 600 /etc/chameleon/asc-key.p8"
    scp -q "${ASC_KEY_PATH}" "${NODE_SSH}:/etc/chameleon/asc-key.p8"
    ssh "${NODE_SSH}" "chmod 600 /etc/chameleon/asc-key.p8"
else
    echo ">>> ASC_KEY_PATH not set or file missing — Apple state will be unavailable in admin"
fi

# ── Remote deploy ──────────────────────────────────────────────────────────
echo ">>> Running deploy on ${NODE_SSH}..."
ssh "${NODE_SSH}" bash -s -- \
    "${CHAMELEON_DB_PASSWORD}" \
    "${CHAMELEON_REDIS_PASSWORD}" \
    "${CHAMELEON_ADMIN_JWT_SECRET}" \
    "${CHAMELEON_ADMIN_PASSWORD}" \
    "${CHAMELEON_USER_API_SECRET}" \
    "${CHAMELEON_CLUSTER_SECRET:-}" \
    "${NODE_NODE_ID}" \
    "${NODE_SNI}" \
    "${NODE_DIR}" \
    "${NODE_PREBUILT}" \
    "${WITH_SINGBOX}" \
    "${BOT_TOKEN:-}" \
    "${ADMIN_IDS:-170181045 6668749877}" \
    "${FREEKASSA_SHOP_ID:-}" \
    "${FREEKASSA_API_KEY:-}" \
    "${FREEKASSA_SECRET1:-}" \
    "${FREEKASSA_SECRET2:-}" \
    "${RESEND_API_KEY:-}" \
    "${GOOGLE_IOS_CLIENT_ID:-}" \
    "${CHAMELEON_PROVIDERS_ENCRYPTION_KEY:-}" \
    "${CHAMELEON_MSK_USER_API_SECRET:-}" \
    "${ASC_KEY_ID:-}" \
    "${ASC_ISSUER_ID:-}" \
    "${ASC_APP_ID:-}" \
    "${CHAMELEON_GRAFANA_PASSWORD:-}" \
    "${B2_KEY_ID:-}" \
    "${B2_APPLICATION_KEY:-}" \
    "${B2_BUCKET:-}" \
    "${B2_ENDPOINT:-}" \
    "${B2_REGION:-}" \
    "${APNS_KEY_ID:-}" \
    "${APNS_TEAM_ID:-}" \
    "${APNS_BUNDLE_ID:-}" \
    "${APNS_KEY_P8_B64:-}" \
    <<'REMOTE'
set -euo pipefail

DB_PASSWORD="$1"
REDIS_PASSWORD="$2"
JWT_SECRET="$3"
ADMIN_PASSWORD="$4"
USER_API_SECRET="$5"
CLUSTER_SECRET="$6"
NODE_ID="$7"
NODE_SNI="$8"
REMOTE_DIR="$9"
PREBUILT="${10}"
WITH_SINGBOX="${11}"
TG_BOT_TOKEN="${12}"
TG_CHAT_IDS="${13}"
FREEKASSA_SHOP_ID="${14}"
FREEKASSA_API_KEY="${15}"
FREEKASSA_SECRET1="${16}"
FREEKASSA_SECRET2="${17}"
RESEND_API_KEY="${18}"
GOOGLE_IOS_CLIENT_ID="${19}"
CHAMELEON_PROVIDERS_ENCRYPTION_KEY="${20}"
CHAMELEON_MSK_USER_API_SECRET="${21}"
ASC_KEY_ID="${22}"
ASC_ISSUER_ID="${23}"
ASC_APP_ID="${24}"
CHAMELEON_GRAFANA_PASSWORD="${25}"
B2_KEY_ID="${26}"
B2_APPLICATION_KEY="${27}"
B2_BUCKET="${28}"
B2_ENDPOINT="${29}"
B2_REGION="${30}"
APNS_KEY_ID="${31}"
APNS_TEAM_ID="${32}"
APNS_BUNDLE_ID="${33}"
APNS_KEY_P8_B64="${34}"

cd "${REMOTE_DIR}/backend"

# ── Config ─────────────────────────────────────────────────────────────────
cp config.production.yaml config.yaml
sed -i "s/node_id: \"\"/node_id: \"${NODE_ID}\"/" config.yaml
sed -i "s/default: \"ads.adfox.ru\"/default: \"${NODE_SNI}\"/" config.yaml

# Set cluster peers (each node points to all other nodes).
# 2026-05-26: DE retired (OVH expired) — single-NL world. nl2-1 has no
# peers. Empty array short-circuits cluster.Start() and stops the
# reconcileLoop from hammering a dead peer every 5 min. Re-add real
# peers when a 2nd node is provisioned (and INFRA-SYNC-01 is fixed
# so payments/id_aliases actually replicate).
case "$NODE_ID" in
    de-1) PEER_BLOCK='  peers:\n    - id: "nl2-1"\n      url: "http://147.45.252.234:8000"' ;;
    nl2-1) PEER_BLOCK='  peers: []' ;;
    *) PEER_BLOCK='  peers: []' ;;
esac
sed -i "s|  peers: \[\]|${PEER_BLOCK}|" config.yaml
echo ">>> Cluster sync configured (node=${NODE_ID}, peers per above)"

# Per-node UDP protocol overrides (Hysteria2 + TUIC v5)
case "$NODE_ID" in
    de-1)
        sed -i 's/hysteria2_port: 0/hysteria2_port: 443/' config.yaml
        sed -i 's/tuic_port: 0/tuic_port: 8443/' config.yaml
        sed -i 's|udp_cert_path: ""|udp_cert_path: "/etc/singbox/server.crt"|' config.yaml
        sed -i 's|udp_key_path: ""|udp_key_path: "/etc/singbox/server.key"|' config.yaml
        echo ">>> UDP protocols enabled: Hysteria2=443, TUIC=8443"
        ;;
    nl2-1)
        # Hysteria2 fallback leg for the sole prod node. TUIC intentionally
        # left off — one UDP fallback is enough and keeps the surface small.
        # Reuses the self-signed cert already in the singbox-config volume.
        # SEC-03 (post-2026-06-01): the client PINS this cert AND verifies
        # tls.server_name=<SNI>, so the cert MUST carry SAN=<SNI> — a SAN-less
        # cert makes every UDP leg fail name verification ("not valid for any
        # names") and silently kills the whole H2/TUIC fallback. See the SAN
        # guard below + incidents/2026-06-06-udp-fallback-cert-san.md.
        # UDP/443 is already open in ufw. Hysteria2 reaches NL's IP directly
        # (the SPB/MSK relays are TCP-only and don't carry UDP).
        #
        # Salamander obfs: wraps the QUIC packets so RKN DPI can't fingerprint
        # them as QUIC (it throttles raw QUIC to zero after the handshake —
        # which is why an un-obfuscated H2 "pings" but carries no traffic). The
        # SAME PSK is plumbed into the generated client outbound (clientconfig.go
        # reads cfg.VPN.Hysteria2ObfsPassword), so server and client always match.
        sed -i 's/hysteria2_port: 0/hysteria2_port: 443/' config.yaml
        sed -i 's|udp_cert_path: ""|udp_cert_path: "/etc/singbox/server.crt"|' config.yaml
        sed -i 's|udp_key_path: ""|udp_key_path: "/etc/singbox/server.key"|' config.yaml
        sed -i 's|hysteria2_obfs_password: ""|hysteria2_obfs_password: "madfrog-salamander-7Kx9q2"|' config.yaml
        # Egress through clean US-geo IP 72.56.79.25 (additional Timeweb IP, reads US
        # not RU) so geo-services (Gemini) don't see Russia. Main IP 147.45.252.234
        # stays the inbound. See roadmap NL-GEO (2026-05-31).
        sed -i 's|egress_bind_ip: ""|egress_bind_ip: "72.56.79.25"|' config.yaml
        echo ">>> UDP protocols enabled: Hysteria2=443 + Salamander obfs (TUIC off); egress→72.56.79.25"
        ;;
    *)
        echo ">>> UDP protocols disabled on this node"
        ;;
esac

# ── UDP cert SAN guard (incident 2026-06-06) ────────────────────────────────
# The Hysteria2/TUIC client legs pin this cert AND verify tls.server_name=<SNI>,
# so the cert MUST carry SAN=<SNI> or every UDP leg fails name verification and
# the fallback is silently dead. ALL UDP exit nodes must serve the IDENTICAL
# cert (the client pins ONE cert, engineCfg.UDPCertPEM, for every UDP leg) — so
# we do NOT auto-regenerate here (that would diverge per-node certs and break
# the shared pin). We warn loudly instead; fix via the incident playbook.
if grep -q 'udp_cert_path: "/etc/singbox/server.crt"' config.yaml; then
    UDP_CERT_VOL=/var/lib/docker/volumes/chameleon-singbox-config/_data/server.crt
    if [ -f "$UDP_CERT_VOL" ]; then
        if openssl x509 -in "$UDP_CERT_VOL" -noout -ext subjectAltName 2>/dev/null | grep -q "$NODE_SNI"; then
            echo ">>> UDP cert SAN OK (contains $NODE_SNI)"
        else
            echo "!!! WARNING: UDP cert $UDP_CERT_VOL has NO SAN=$NODE_SNI — H2/TUIC fallback is DEAD."
            echo "!!!   Fix: regenerate with -addext subjectAltName=DNS:$NODE_SNI and copy the SAME"
            echo "!!!   cert+key to every UDP exit node. See docs/incidents/2026-06-06-udp-fallback-cert-san.md"
        fi
    else
        echo "!!! WARNING: UDP enabled but $UDP_CERT_VOL is missing — H2/TUIC legs will be skipped."
    fi
fi

# .env — Reality keys are in DB now, not here
cat > .env <<EOF
DB_PASSWORD=${DB_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
JWT_SECRET=${JWT_SECRET}
USER_API_SECRET=${USER_API_SECRET}
CLUSTER_SECRET=${CLUSTER_SECRET}
FREEKASSA_SHOP_ID=${FREEKASSA_SHOP_ID}
FREEKASSA_API_KEY=${FREEKASSA_API_KEY}
FREEKASSA_SECRET1=${FREEKASSA_SECRET1}
FREEKASSA_SECRET2=${FREEKASSA_SECRET2}
RESEND_API_KEY=${RESEND_API_KEY}
GOOGLE_IOS_CLIENT_ID=${GOOGLE_IOS_CLIENT_ID}
CHAMELEON_PROVIDERS_ENCRYPTION_KEY=${CHAMELEON_PROVIDERS_ENCRYPTION_KEY}
CHAMELEON_MSK_USER_API_SECRET=${CHAMELEON_MSK_USER_API_SECRET}
ASC_KEY_ID=${ASC_KEY_ID}
ASC_ISSUER_ID=${ASC_ISSUER_ID}
ASC_APP_ID=${ASC_APP_ID}
CHAMELEON_GRAFANA_PASSWORD=${CHAMELEON_GRAFANA_PASSWORD}
B2_KEY_ID=${B2_KEY_ID}
B2_APPLICATION_KEY=${B2_APPLICATION_KEY}
B2_BUCKET=${B2_BUCKET}
B2_ENDPOINT=${B2_ENDPOINT}
B2_REGION=${B2_REGION}
APNS_KEY_ID=${APNS_KEY_ID}
APNS_TEAM_ID=${APNS_TEAM_ID}
APNS_BUNDLE_ID=${APNS_BUNDLE_ID}
APNS_KEY_P8_B64=${APNS_KEY_P8_B64}
EOF
chmod 600 .env

# MON-06: ensure /var/log/singbox-events.jsonl exists AS A FILE before
# docker-compose mounts it. If the path doesn't exist, Docker silently
# creates it as a DIRECTORY which then fails the Python watcher's
# `open(file, "a")` with IsADirectoryError. Pre-creating the file
# prevents that race forever.
sudo touch /var/log/singbox-events.jsonl
sudo chmod 644 /var/log/singbox-events.jsonl

# Same trick for the ASC key — if the operator hasn't scp'd a real .p8
# yet, ensure the mount target exists as a file (even if empty) so
# docker doesn't auto-create a directory. asc.New() on empty PEM
# returns nil → Status page renders "ASC not configured" cleanly.
sudo mkdir -p /etc/chameleon
sudo touch /etc/chameleon/asc-key.p8
sudo chmod 600 /etc/chameleon/asc-key.p8

# Telegram alerts config
if [ -n "$TG_BOT_TOKEN" ]; then
    printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_IDS="%s"\n' \
        "${TG_BOT_TOKEN}" "${TG_CHAT_IDS}" \
        | sudo tee /etc/chameleon-alerts.env > /dev/null
    sudo chmod 644 /etc/chameleon-alerts.env
    echo ">>> Telegram alerts configured"
fi

# ── Run migrations (fail-fast, errors visible) ─────────────────────────────
# PRODUCT-MATURITY-LOOP D1 (2026-06-21): the old loop ran
#   psql ... < "$f" 2>/dev/null && echo "Applied"
# which (a) had no ON_ERROR_STOP so psql plowed past a failing statement,
# (b) discarded stderr, and (c) being a non-final command in an &&-list was
# exempt from `set -e` — so a failed migration was INVISIBLE and the deploy
# reported success then built/restarted against a half-applied schema (the
# documented NL legacy-table footgun, made systemic).
# Now: ON_ERROR_STOP=1 aborts the file on the first SQL error, stderr is
# surfaced, and a failure ABORTS the deploy before the build/restart steps.
# All numbered migrations are idempotent (IF NOT EXISTS / DROP IF EXISTS /
# ON CONFLICT DO NOTHING / WHERE NOT EXISTS), so re-running after a fix is safe.
echo ">>> Running DB migrations..."
migration_failed=0
for f in migrations/0[0-9][0-9]_*.sql; do
    [ -f "$f" ] || continue
    if docker exec -i chameleon-postgres psql -v ON_ERROR_STOP=1 -U chameleon -d chameleon < "$f"; then
        echo "    Applied: $f"
    else
        echo "    !! FAILED: $f (see psql error above)"
        migration_failed=1
        break
    fi
done
if [ "$migration_failed" -ne 0 ]; then
    echo ""
    echo ">>> ✗ ABORTING DEPLOY — a migration failed; schema may be partially applied."
    echo ">>>   Fix the offending migration, then re-run ./deploy.sh (migrations are idempotent)."
    echo ">>>   Verify on the box: docker exec -it chameleon-postgres psql -U chameleon -d chameleon -c '\\dt'"
    exit 1
fi

# ── Docker volumes ─────────────────────────────────────────────────────────
docker volume create chameleon-pgdata 2>/dev/null || true
docker volume create chameleon-redisdata 2>/dev/null || true
docker volume create chameleon-singbox-config 2>/dev/null || true

# ── Build chameleon ────────────────────────────────────────────────────────
if [ "$PREBUILT" -eq 1 ]; then
    echo ">>> Building from pre-compiled binary..."
    docker build -f Dockerfile.prebuilt -t backend-chameleon . 2>&1 | tail -3
else
    echo ">>> Building from source..."
    docker compose build chameleon 2>&1 | tail -5
fi

# ── Build nginx (COPY-only from the locally-built SPA dist) ────────────────
# The SPA is built locally (see "Building admin SPA locally" above) and
# shipped as clients/admin/dist. We do NOT run npm/vite here — it OOMs the
# 2GB box and the OOM-killer restarts singbox (2026-05-29 incident). This
# build is just a COPY of the prebuilt dist, so it's near-instant and uses
# no meaningful memory. cwd is ${REMOTE_DIR}/backend, so ../clients/admin
# is the shipped SPA tree.
echo ">>> Building nginx (COPY-only from prebuilt SPA dist)..."
if [ ! -d ../clients/admin/dist ]; then
    echo "!!! ../clients/admin/dist missing — SPA was not shipped; aborting" >&2
    exit 1
fi
docker build -f ../clients/admin/Dockerfile.prebuilt-spa -t backend-nginx:latest ../clients/admin 2>&1 | tail -3

# ── Ensure docker-socket-proxy is up (MED-010) ────────────────────────────
# chameleon depends on this proxy for `docker ps` (metrics) and
# `docker kill` (singbox HUP/TERM) since the direct /var/run/docker.sock
# bind was removed. Pull image + start before chameleon so the dependency
# is satisfied at chameleon startup.
echo ">>> Starting docker-socket-proxy..."
docker compose up -d --no-deps docker-socket-proxy
# Brief wait for proxy to be listening on :2375 before chameleon tries to
# connect during its own boot.
sleep 2

# ── Restart chameleon ONLY (singbox is standalone, compose can't touch it) ─
echo ">>> Starting chameleon + nginx..."
# Project name comes from the directory; after the backend-go → backend
# rename the new compose project tries to claim the same container names
# the previous project still owns. Force-recreate releases them cleanly.
docker compose up -d --no-deps --force-recreate chameleon
# --no-build: use the COPY-only backend-nginx:latest image built above; never
# trigger the multi-stage source build here (it would OOM the box).
docker compose up -d --no-deps --no-build --force-recreate nginx

# ── Wait for health ────────────────────────────────────────────────────────
echo ">>> Waiting for backend health..."
for i in $(seq 1 90); do
    if wget -qO- http://localhost:8000/health 2>/dev/null | grep -q '"status"'; then
        echo ">>> Backend is healthy!"
        break
    fi
    if [ "$i" -eq 90 ]; then
        echo ">>> ERROR: Backend did not become healthy in 90s"
        docker compose logs chameleon --tail 50
        exit 1
    fi
    sleep 1
done

# ── Create admin user (idempotent) ─────────────────────────────────────────
docker compose exec -T chameleon chameleon admin create \
    --config /etc/chameleon/config.yaml \
    --username admin --password "${ADMIN_PASSWORD}" --role admin 2>/dev/null || true

# ── Singbox (only if --with-singbox) ───────────────────────────────────────
if [ "$WITH_SINGBOX" -eq 1 ]; then
    echo ">>> Restarting singbox (VPN will briefly drop)..."
    chmod +x scripts/singbox-run.sh
    ./scripts/singbox-run.sh --force
fi

# ── Install watchdog cron (idempotent) ─────────────────────────────────────
chmod +x "${REMOTE_DIR}/backend/scripts/"*.sh 2>/dev/null || true

# Watchdog cron (every minute) — installed as ROOT so the script can write
# /var/log/ and doesn't need interactive sudo for `test -f` on docker volume.
# Previously installed under ubuntu user → log file never created and sudo calls
# inside the script failed silently, letting singbox stay dead indefinitely.
WATCHDOG="${REMOTE_DIR}/backend/scripts/singbox-watchdog.sh"
if [ -f "$WATCHDOG" ]; then
    CRON_LINE="* * * * * ${WATCHDOG} >> /var/log/singbox-watchdog.log 2>&1"
    sudo bash -c "(crontab -l 2>/dev/null | grep -v 'singbox-watchdog' ; echo '$CRON_LINE') | crontab -"
    # Also remove stale user-level cron from earlier deploys.
    (crontab -l 2>/dev/null | grep -v "singbox-watchdog") | crontab - 2>/dev/null || true
    echo ">>> Watchdog cron installed (root)"
fi

# Health check cron (every minute) — also root for the same reason.
HEALTHCHECK="${REMOTE_DIR}/backend/scripts/health-check.sh"
if [ -f "$HEALTHCHECK" ]; then
    CRON_LINE="* * * * * ${HEALTHCHECK} >> /var/log/chameleon-health.log 2>&1"
    sudo bash -c "(crontab -l 2>/dev/null | grep -v 'health-check' ; echo '$CRON_LINE') | crontab -"
    (crontab -l 2>/dev/null | grep -v "health-check") | crontab - 2>/dev/null || true
    echo ">>> Health check cron installed (root)"
fi

# MON-06: singbox-log-watcher cron (every minute) — scrapes the last 65s of
# `docker logs singbox` for VLESS Reality TLS handshake failures and writes
# a per-tick JSONL summary to /var/log/singbox-events.jsonl. The admin
# /status/handshake-errors endpoint reads that file and renders a chart.
SINGBOX_WATCH="${REMOTE_DIR}/backend/scripts/singbox-log-watcher.py"
if [ -f "$SINGBOX_WATCH" ]; then
    # Pre-create the log file with the right perms so the chameleon
    # container's ro bind-mount succeeds and the cron-as-root writer
    # can append. mode 644 is fine — file contains aggregate counts,
    # no per-user PII.
    sudo touch /var/log/singbox-events.jsonl
    sudo chmod 644 /var/log/singbox-events.jsonl
    CRON_LINE="* * * * * /usr/bin/python3 ${SINGBOX_WATCH} >> /var/log/singbox-watcher.err 2>&1"
    sudo bash -c "(crontab -l 2>/dev/null | grep -v 'singbox-log-watcher' ; echo '$CRON_LINE') | crontab -"
    (crontab -l 2>/dev/null | grep -v "singbox-log-watcher") | crontab - 2>/dev/null || true
    echo ">>> Singbox log watcher cron installed (root)"
fi

# Log monitor cron (every minute) — scans docker logs for critical patterns and
# alerts via Telegram. Motivated by 2026-05-12 NL Postgres read-only incident:
# traffic-collector + cluster sync failed silently for 12+ hours.
LOGMONITOR="${REMOTE_DIR}/backend/scripts/log-monitor.sh"
if [ -f "$LOGMONITOR" ]; then
    CRON_LINE="* * * * * ${LOGMONITOR} >> /var/log/chameleon-monitor.log 2>&1"
    sudo bash -c "(crontab -l 2>/dev/null | grep -v 'log-monitor' ; echo '$CRON_LINE') | crontab -"
    (crontab -l 2>/dev/null | grep -v "log-monitor") | crontab - 2>/dev/null || true
    echo ">>> Log monitor cron installed (root)"
fi

# DB backup cron (daily at 3:00 AM) — installed as ROOT because script writes
# to /var/backups/chameleon and /var/log/chameleon-backup.log (both root-owned).
# Previously installed under deploy user → cron fired but script failed silently
# on permission denied, so backups stopped without any visible error.
BACKUP="${REMOTE_DIR}/backend/scripts/db-backup.sh"
if [ -f "$BACKUP" ]; then
    CRON_LINE="0 3 * * * ${BACKUP} >> /var/log/chameleon-backup.log 2>&1"
    sudo bash -c "(crontab -l 2>/dev/null | grep -v 'db-backup' ; echo '$CRON_LINE') | crontab -"
    (crontab -l 2>/dev/null | grep -v "db-backup") | crontab - 2>/dev/null || true
    echo ">>> DB backup cron installed (root, daily 3:00 AM)"
fi

# ── Post-deploy verification ──────────────────────────────────────────────
echo ""
echo "╔═══ POST-DEPLOY CHECKS ═══╗"

# Check chameleon
if wget -qO- http://localhost:8000/health 2>/dev/null | grep -q '"status":"ok"'; then
    echo "║ ✓ Chameleon API: OK"
else
    echo "║ ✗ Chameleon API: FAIL"
fi

# Check singbox container — auto-start if it exists but is stopped.
# Reason: `unless-stopped` policy does NOT auto-restart after manual docker stop,
# so a leftover stopped singbox from a previous session silently breaks VPN.
if docker ps --filter "name=singbox" --filter "status=running" -q | grep -q .; then
    echo "║ ✓ Singbox container: RUNNING"
elif docker ps -a --filter "name=singbox" -q | grep -q .; then
    echo "║ ⚠ Singbox container: STOPPED — auto-starting..."
    if docker start singbox >/dev/null 2>&1; then
        sleep 2
        if docker ps --filter "name=singbox" --filter "status=running" -q | grep -q .; then
            echo "║ ✓ Singbox container: RECOVERED"
        else
            echo "║ ✗ Singbox container: FAILED TO START"
            docker logs singbox --tail 20
        fi
    else
        echo "║ ✗ Singbox container: docker start failed"
    fi
else
    echo "║ ✗ Singbox container: NOT FOUND"
    echo "║   Run: ./scripts/singbox-run.sh"
fi

# Check User API
if curl -sf http://127.0.0.1:15380/api/v1/inbounds -o /dev/null 2>/dev/null; then
    echo "║ ✓ User API (15380): OK"
else
    echo "║ ✗ User API (15380): NOT RESPONDING"
fi

# Check VPN port
if ss -tlnp 2>/dev/null | grep -q ':2096' || netstat -tlnp 2>/dev/null | grep -q ':2096'; then
    echo "║ ✓ VPN port 2096: LISTENING"
else
    echo "║ ✗ VPN port 2096: NOT LISTENING"
fi

# Check clash API
if curl -sf http://127.0.0.1:9090/ -o /dev/null 2>/dev/null; then
    echo "║ ✓ Clash API (9090): OK"
else
    echo "║ ✗ Clash API (9090): NOT RESPONDING"
fi

echo "╚══════════════════════════╝"
echo ""
echo ">>> Deploy complete!"
REMOTE

# Cleanup local binary
if [ "$NODE_PREBUILT" -eq 1 ] && [ -f "$SCRIPT_DIR/chameleon-linux" ]; then
    rm "$SCRIPT_DIR/chameleon-linux"
fi

echo "=== Done: ${NODE} deployed ==="
