#!/usr/bin/env bash
# ============================================================
#  WAW origin healthcheck — EXTERNAL off-primary vantage (GRA / OVH)
#  Successor to nl-origin-healthcheck.sh (renamed 2026-07-01 after the NL→WAW
#  failover: NL is retired as the origin, WAW is now primary backend+web).
#
#  Lives OFF the monitored box (WAW) so a WAW/OVH-Warsaw outage cannot silence it
#  — WAW's own health-check would go mute exactly when it matters (the lesson from
#  the 2026-06-26 NL outage, ADR 0012). Checks the public origin the way a real
#  visitor hits it: madfrog.online (Cloudflare → WAW:80 → nginx → backend :8000).
#  CF returns 52x when the origin is down (it does NOT mask origin-down), so a
#  non-200 here means WAW is actually unreachable.
#
#  Alerts on state TRANSITIONS (DOWN / RECOVERED) + re-alerts every 30m while
#  down, so it doubles as the "WAW is back" notifier. No per-run spam.
#  Install (GRA):  */5 * * * * /home/debian/monitoring/waw-origin-healthcheck.sh >> /home/debian/monitoring/waw-origin.log 2>&1
#
#  NOTE: the RU API ingress (api.madfrog.online → MSK relay → WAW) is monitored
#  separately from a real RU vantage by ru-auth-healthcheck.sh ON the MSK relay.
#  We deliberately do NOT probe api.madfrog.online from GRA: the France→Russia
#  hop is slow (~1.8s) and flaky, which produced false timeouts. Gap: if the MSK
#  relay itself dies, its on-box monitor goes mute — a dedicated reliable external
#  RU-ingress probe is future work (roadmap).
# ============================================================
set -uo pipefail
HOST="madfrog.online"          # Cloudflare-proxied apex → WAW:80 (the live origin)
TIMEOUT="${TIMEOUT:-8}"
REALERT="${REALERT:-1800}"     # re-alert every 30 min while still down
CONFIRM="${CONFIRM:-2}"        # consecutive failures required before paging (ride out edge blips)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALERT="${SCRIPT_DIR}/telegram-alert.sh"
STATE="${SCRIPT_DIR}/.waw-origin.state"
STREAK="${SCRIPT_DIR}/.waw-origin.streak"
LASTALERT="${SCRIPT_DIR}/.waw-origin.lastalert"

# Return ONLY curl's recorded HTTP status (no `|| echo` double-append — see the
# ru-auth-healthcheck.sh code() comment; that bug produced "000000"/"200000").
code(){ local c; c=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$@" 2>/dev/null); printf '%s' "${c:-000}"; }

API=$(code "https://${HOST}/health")
ts=$(date -u +%FT%TZ)
LINE="origin_health(madfrog.online via CF→WAW)=${API}"
echo "[$ts] ${LINE}"

alert(){ [ -x "$ALERT" ] && "$ALERT" "$1" || true; }
now=$(date +%s)
prev=ok; [ -f "$STATE" ] && prev=$(cat "$STATE")

# Flap damping: count consecutive failures; only page after $CONFIRM in a row.
cnt=0; [ -f "$STREAK" ] && cnt=$(cat "$STREAK")
if [ "$API" = "200" ]; then cnt=0; else cnt=$((cnt + 1)); fi
echo "$cnt" > "$STREAK"

if [ "$API" = "200" ]; then
  [ "$prev" = "down" ] && alert "✅ WAW ORIGIN RECOVERED (GRA vantage). ${LINE}"
  echo ok > "$STATE"; rm -f "$LASTALERT"; exit 0
fi

# non-200: only escalate once the failure is confirmed ($CONFIRM consecutive runs).
if [ "$cnt" -ge "$CONFIRM" ]; then
  last=0; [ -f "$LASTALERT" ] && last=$(cat "$LASTALERT")
  if [ "$prev" != "down" ] || [ $((now - last)) -ge "$REALERT" ]; then
    alert "🔴 WAW origin unreachable via Cloudflare (GRA vantage) — madfrog.online down. ${LINE}"
    echo "$now" > "$LASTALERT"
  fi
  echo down > "$STATE"
fi
exit 2
