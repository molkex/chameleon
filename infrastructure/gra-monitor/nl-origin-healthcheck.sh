#!/usr/bin/env bash
# ============================================================
#  NL origin + API healthcheck — EXTERNAL off-Timeweb vantage (GRA / OVH)
#  NL-RED-MON (ADR 0012, incident 2026-06-26). Lives OFF the monitored box so a
#  Timeweb/NL outage cannot silence it (health-check.sh runs ON NL → it went mute
#  on 2026-06-26). Alerts on state TRANSITIONS (DOWN / RECOVERED) + re-alerts
#  every 30m while down, so it doubles as the "NL is back" notifier.
#  Install (GRA):  */5 * * * * /home/debian/monitoring/nl-origin-healthcheck.sh >> /home/debian/monitoring/nl-origin.log 2>&1
# ============================================================
set -uo pipefail
HOST="api.madfrog.online"
NL_IP="147.45.252.234"
TIMEOUT="${TIMEOUT:-8}"
REALERT=1800   # re-alert every 30 min while still down
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALERT="${SCRIPT_DIR}/telegram-alert.sh"
STATE="${SCRIPT_DIR}/.nl-origin.state"
LASTALERT="${SCRIPT_DIR}/.nl-origin.lastalert"

code(){ curl -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$@" 2>/dev/null || echo 000; }
tcp(){ timeout "$TIMEOUT" bash -c "echo >/dev/tcp/$1/$2" 2>/dev/null && echo up || echo down; }

API=$(code "https://${HOST}/health")     # user-facing path (MSK relay -> NL)
NL80=$(tcp "$NL_IP" 80)                   # direct origin reachability from GRA
NL443=$(tcp "$NL_IP" 443)
ts=$(date -u +%FT%TZ)
LINE="api_health=${API} nl:80=${NL80} nl:443=${NL443}"
echo "[$ts] ${LINE}"

alert(){ [ -x "$ALERT" ] && "$ALERT" "$1" || true; }
now=$(date +%s)
prev=ok; [ -f "$STATE" ] && prev=$(cat "$STATE")

# Healthy == the user-facing API answers 200 (the thing that actually matters).
if [ "$API" = "200" ]; then
  [ "$prev" = "down" ] && alert "✅ NL ORIGIN RECOVERED (GRA vantage). ${LINE}"
  echo ok > "$STATE"; rm -f "$LASTALERT"; exit 0
fi

echo down > "$STATE"
last=0; [ -f "$LASTALERT" ] && last=$(cat "$LASTALERT")
if [ "$prev" != "down" ] || [ $((now - last)) -ge "$REALERT" ]; then
  scope="🔴 NL origin unreachable"
  [ "$NL80" = "up" ] && scope="🟠 NL origin UP but api.madfrog.online failing (MSK relay / nginx?)"
  alert "${scope} (GRA vantage). ${LINE}"
  echo "$now" > "$LASTALERT"
fi
exit 2
