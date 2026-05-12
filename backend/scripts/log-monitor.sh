#!/bin/bash
# Log monitor — scans last 60s of `docker logs chameleon` for critical patterns,
# dedupes alerts (30 min per pattern), sends Telegram alert via telegram-alert.sh.
# Install: crontab -e → * * * * * /opt/chameleon/backend/scripts/log-monitor.sh >> /var/log/chameleon-monitor.log 2>&1
#
# Background (2026-05-12): NL backend Postgres sat read-only for 12+ hours.
# Traffic-collector + cluster sync silently failed every minute and nobody noticed.
# This script catches that class of silent failure: read-only DB, auth errors,
# any "level":"error" in mobile/{auth,config}.go, and any "level":"fatal".
#
# Exits 0 always (cron-friendly): a monitor that fails noisily is worse than no monitor.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINER="chameleon"
WINDOW="60s"
ALERT_INTERVAL=1800  # 30 min dedupe
STATE_DIR="/var/run/chameleon-monitor"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"

mkdir -p "$STATE_DIR" 2>/dev/null || true

# ── Identify node ──────────────────────────────────────────────────────────
# Prefer NODE_ID from /opt/chameleon/backend/.env, fall back to hostname.
NODE_LABEL=""
ENV_FILE="/opt/chameleon/backend/.env"
if [ -f "$ENV_FILE" ]; then
    NODE_LABEL=$(grep -E '^NODE_ID=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
fi
if [ -z "$NODE_LABEL" ]; then
    HN=$(hostname -f 2>/dev/null || hostname)
    case "$HN" in
        *de*|*162.19.242.30*) NODE_LABEL="DE" ;;
        *nl*|*147.45.252.234*) NODE_LABEL="NL" ;;
        *) NODE_LABEL="$HN" ;;
    esac
fi

# ── Pull log window ────────────────────────────────────────────────────────
LOGS=$(docker logs "$CONTAINER" --since "$WINDOW" 2>&1 || true)
if [ -z "$LOGS" ]; then
    exit 0
fi

# ── Dedupe + fire ──────────────────────────────────────────────────────────
# Skip the alert if the lock file for this pattern_id was touched within
# ALERT_INTERVAL seconds. Otherwise touch it and send.
fire_alert() {
    local pattern_id="$1" name="$2" count="$3" sample="$4"
    local lock="$STATE_DIR/${pattern_id}.lock"
    local now=$(date +%s)
    if [ -f "$lock" ]; then
        local last
        last=$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo 0)
        if [ $((now - last)) -lt $ALERT_INTERVAL ]; then
            echo "${LOG_PREFIX} [$pattern_id] suppressed (cooldown, count=$count)"
            return
        fi
    fi
    touch "$lock"

    # Trim sample to 200 chars, strip HTML-significant chars for Telegram parse_mode=HTML.
    local trimmed
    trimmed=$(printf '%s' "$sample" | tr -d '\r' | cut -c1-200 | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

    local msg
    msg=$(printf '🚨 <b>%s</b>: %s\nCount in 60s: %d\nSample: <code>%s</code>' \
        "$NODE_LABEL" "$name" "$count" "$trimmed")

    echo "${LOG_PREFIX} [$pattern_id] FIRED count=$count"
    [ -x "$SCRIPT_DIR/telegram-alert.sh" ] && \
        "$SCRIPT_DIR/telegram-alert.sh" "$msg" || true
}

# Check one pattern. Args: pattern_id, human_name, grep_regex, [exclude_regex]
check_pattern() {
    local pattern_id="$1" name="$2" regex="$3" exclude="${4:-}"
    local matches
    if [ -n "$exclude" ]; then
        matches=$(printf '%s\n' "$LOGS" | grep -E "$regex" | grep -Ev "$exclude" || true)
    else
        matches=$(printf '%s\n' "$LOGS" | grep -E "$regex" || true)
    fi
    [ -z "$matches" ] && return
    local count
    count=$(printf '%s\n' "$matches" | grep -c . || true)
    local sample
    sample=$(printf '%s\n' "$matches" | head -1)
    fire_alert "$pattern_id" "$name" "$count" "$sample"
}

# ── Patterns ───────────────────────────────────────────────────────────────
# 1. Postgres read-only — the bug that motivated this monitor.
check_pattern \
    "pg-readonly" \
    "Postgres read-only" \
    "cannot execute .* in a read-only transaction"

# 2. Apple auth DB errors — but ignore "context canceled" which is normal client cancel.
check_pattern \
    "apple-auth-db" \
    "Apple auth DB errors" \
    "find user by apple_id.*error" \
    "context canceled"

# 3. Any structured error from mobile/auth.go or mobile/config.go.
#    Caller field in zap logs looks like "caller":"mobile/auth.go:123".
check_pattern \
    "mobile-auth-config-err" \
    "Auth/config errors" \
    '"level":"error".*"caller":"[^"]*mobile/(auth|config)\.go'

# 4. Any fatal — should never happen in steady-state.
check_pattern \
    "fatal" \
    "Fatal log" \
    '"level":"fatal"'

exit 0
