#!/bin/bash
# Health check — runs every minute via cron
#
# Checks (any failure → Telegram alert, rate-limited 1 per 5 min per key):
#   - chameleon API:  /health returns {"status":"ok"}
#   - singbox container:  exact-name running (not the ss-ws sibling)
#   - VPN port:  ${VPN_PORT:-443} listening
#   - postgres:  pg_isready inside chameleon-postgres
#   - redis:     redis-cli ping inside chameleon-redis
#   - disk:      / partition usage < 85%
#   - RAM:       used/total < 90%
#   - swap:      swap_used/swap_total < 10% (warning of memory pressure)
#   - backup:    latest /var/log/chameleon-backup.log success < 30h ago
#
# Each check is wrapped so one failing dependency (e.g. docker daemon down,
# postgres container restarting) doesn't abort the rest. `set -e` is
# DELIBERATELY NOT used — we want every check to run every tick.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
ALERT_INTERVAL=300
STATE_DIR="/tmp/chameleon-health"
FAIL_DIR="/tmp/chameleon-health/fails"
mkdir -p "$STATE_DIR" "$FAIL_DIR"

# Require N consecutive failures before alerting. Each cron tick that fails
# increments a per-key counter; success resets it. A single-tick blip
# (typical during `docker compose up --force-recreate` which leaves /health
# unreachable for 5-15s) no longer pages — real outages still trigger
# within MIN_FAILS minutes since cron fires every minute.
#
# MIN_FAILS=2 → ≥2 min of continuous failure before the first alert.
# Tune up to 3 if deploys regularly span >1 tick; tune to 1 if false-
# negative tolerance is lower than false-positive tolerance.
MIN_FAILS=2

record_fail() {
    local key="$1"
    local fail_file="$FAIL_DIR/$key"
    local count=0
    [ -f "$fail_file" ] && count=$(cat "$fail_file")
    count=$((count + 1))
    echo "$count" > "$fail_file"
    echo "$count"
}

reset_fail() {
    rm -f "$FAIL_DIR/$1"
}

alert() {
    local key="$1" msg="$2"
    local fails
    fails=$(record_fail "$key")
    if [ "$fails" -lt "$MIN_FAILS" ]; then
        # First (or transient) failure — track it but stay quiet.
        return
    fi
    local last_file="$STATE_DIR/$key"
    local now=$(date +%s)
    if [ -f "$last_file" ]; then
        local last
        last=$(cat "$last_file")
        if [ $((now - last)) -lt $ALERT_INTERVAL ]; then
            return
        fi
    fi
    echo "$now" > "$last_file"
    "$SCRIPT_DIR/telegram-alert.sh" "$msg" || true
}

clear_alert() {
    rm -f "$STATE_DIR/$1"
    reset_fail "$1"
}

# ── chameleon API ──────────────────────────────────────────────────────────
if wget -qO- --timeout=5 http://localhost:8000/health 2>/dev/null | grep -q '"status":"ok"'; then
    clear_alert "chameleon"
else
    alert "chameleon" "⚠️ <b>$HOSTNAME</b>: Chameleon API health check FAILED"
fi

# ── singbox container ──────────────────────────────────────────────────────
# Exact-name match: `--filter "name=singbox"` is a substring filter and would
# match `singbox-ss-ws` too. Use `^/singbox$` on the docker-inspect output
# (docker prefixes container names with "/").
if docker ps --filter "status=running" --format '{{.Names}}' 2>/dev/null | grep -qE '^singbox$'; then
    clear_alert "singbox"
else
    alert "singbox" "🔴 <b>$HOSTNAME</b>: singbox container NOT RUNNING"
fi

# ── VPN port ───────────────────────────────────────────────────────────────
# defaults to 443 (VLESS Reality canonical). Override with VPN_PORT env var
# when a node listens elsewhere. `\b` word boundary so :44300 doesn't match.
VPN_PORT="${VPN_PORT:-443}"
if ss -tlnp 2>/dev/null | grep -q ":${VPN_PORT}\b" || netstat -tlnp 2>/dev/null | grep -q ":${VPN_PORT}\b"; then
    clear_alert "vpn-port"
else
    alert "vpn-port" "🔴 <b>$HOSTNAME</b>: VPN port ${VPN_PORT} NOT LISTENING"
fi

# ── postgres ───────────────────────────────────────────────────────────────
# pg_isready ships with the postgres image, exits 0 when accepting
# connections. Run inside the container so we don't depend on local psql.
if docker exec chameleon-postgres pg_isready -U chameleon -d chameleon -q 2>/dev/null; then
    clear_alert "postgres"
else
    alert "postgres" "🔴 <b>$HOSTNAME</b>: postgres NOT accepting connections"
fi

# ── redis ──────────────────────────────────────────────────────────────────
# redis-cli PING returns "PONG" when alive. Auth-aware: REDIS_PASSWORD lives
# in /opt/chameleon/backend/.env, source it so the ping works on auth-on
# instances. If .env is missing we still try unauthenticated — false-negative
# is better than silent skip.
REDIS_AUTH=""
if [ -f "$SCRIPT_DIR/../.env" ]; then
    # shellcheck disable=SC1091
    REDIS_PASSWORD=$(grep -E '^REDIS_PASSWORD=' "$SCRIPT_DIR/../.env" | head -1 | cut -d= -f2-)
    [ -n "${REDIS_PASSWORD:-}" ] && REDIS_AUTH="-a $REDIS_PASSWORD --no-auth-warning"
fi
if docker exec chameleon-redis sh -c "redis-cli $REDIS_AUTH ping" 2>/dev/null | grep -q '^PONG$'; then
    clear_alert "redis"
else
    alert "redis" "🔴 <b>$HOSTNAME</b>: redis NOT responding to PING"
fi

# ── disk ───────────────────────────────────────────────────────────────────
# df reports percent used as "N%"; strip the % and compare. Threshold 85%
# leaves headroom for log rotation + docker overlay churn before we OOM the
# filesystem. We check / only — other mounts (if any) are app-irrelevant.
DISK_USED=$(df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')
if [ -n "$DISK_USED" ] && [ "$DISK_USED" -ge 85 ]; then
    alert "disk" "⚠️ <b>$HOSTNAME</b>: disk / usage ${DISK_USED}% (threshold 85%)"
else
    clear_alert "disk"
fi

# ── RAM ────────────────────────────────────────────────────────────────────
# free -b for byte-precision so the integer math doesn't lose meaning on
# small VPSes (NL has 1.9 GiB — rounding to MiB loses ~5%). Skip if free is
# unavailable (rare on Linux but defensive).
read -r MEM_TOTAL MEM_USED < <(free -b 2>/dev/null | awk 'NR==2 {print $2, $3}')
if [ -n "${MEM_TOTAL:-}" ] && [ "${MEM_TOTAL:-0}" -gt 0 ]; then
    MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL))
    if [ "$MEM_PCT" -ge 90 ]; then
        alert "ram" "⚠️ <b>$HOSTNAME</b>: RAM usage ${MEM_PCT}% (threshold 90%)"
    else
        clear_alert "ram"
    fi
fi

# ── swap ───────────────────────────────────────────────────────────────────
# Heavy swap use = memory pressure, but ONLY when paired with low available
# RAM. The kernel proactively swaps out idle pages on container hosts after
# every `docker compose up` (dockerd's heap, sleeping process anon pages),
# even though Mem is still healthy — `available > 700 MiB` and `cache > 500
# MiB` together mean we have plenty of room. A solo 10% threshold spammed
# every deploy with false "memory pressure" alerts (2026-05-28 incident).
#
# Real pressure looks like: swap > 40% AND available < 200 MiB. Both
# conditions must hold — either alone is harmless on a 1.9 GiB Docker host.
# Skip cleanly when swap is disabled (total=0).
read -r SWAP_TOTAL SWAP_USED MEM_AVAIL < <(
    free -b 2>/dev/null | awk '
        /^Mem:/  {avail=$7}
        /^Swap:/ {print $2, $3, avail}'
)
if [ -n "${SWAP_TOTAL:-}" ] && [ "${SWAP_TOTAL:-0}" -gt 0 ]; then
    SWAP_PCT=$((SWAP_USED * 100 / SWAP_TOTAL))
    AVAIL_MB=$((${MEM_AVAIL:-0} / 1024 / 1024))
    if [ "$SWAP_PCT" -ge 40 ] && [ "$AVAIL_MB" -lt 200 ]; then
        alert "swap" "⚠️ <b>$HOSTNAME</b>: memory pressure — swap ${SWAP_PCT}%, available ${AVAIL_MB} MiB"
    else
        clear_alert "swap"
    fi
fi

# ── backup age ─────────────────────────────────────────────────────────────
# db-backup.sh writes /var/log/chameleon-backup.log on every run, including
# failures, but only updates the "ok" sentinel on a clean exit (see
# scripts/db-backup.sh). 30h covers a missed nightly run + grace period.
BACKUP_OK="/var/log/chameleon-backup.ok"
if [ -f "$BACKUP_OK" ]; then
    AGE=$(( $(date +%s) - $(stat -c %Y "$BACKUP_OK" 2>/dev/null || echo 0) ))
    if [ "$AGE" -gt $((30 * 3600)) ]; then
        AGE_H=$((AGE / 3600))
        alert "backup" "⚠️ <b>$HOSTNAME</b>: last successful backup ${AGE_H}h ago (threshold 30h)"
    else
        clear_alert "backup"
    fi
fi
# If the sentinel doesn't exist yet (first deploy on this host), don't
# alert — db-backup.sh will create it on first successful run.
