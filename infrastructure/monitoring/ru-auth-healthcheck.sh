#!/usr/bin/env bash
# ============================================================
#  RU-vantage auth-transport healthcheck   (PRODUCT-MATURITY-LOOP, 2026-06-21)
# ============================================================
# WHY THIS EXISTS
#   Sign-in (email / Google / Apple) fails intermittently from Russian IPs and
#   works fine from non-RU IPs. That is NOT three separate auth bugs — it is ONE
#   transport problem: RKN's TSPU SNI-filters `api.madfrog.online` and RSTs the
#   TLS handshake, so EVERY leg that sends that SNI dies, and only the clean-SNI
#   "decoy" leg (ads.adfox.ru → MSK) can carry the request. Apple/Google/magic
#   all ride the same transport, so they all break together on a RU IP.
#
#   Until now the only way to know whether RU sign-in works was to try it by hand
#   on a real device — so we shipped blind and users found the breakage. This
#   script makes it automatic: run it ON the MSK relay (a real RU IP) on a cron
#   and it answers, every few minutes, "can a client in Russia reach the auth
#   backend right now?" — alerting the moment the answer becomes no.
#
# WHAT IT PROBES  (mirrors clients/apple/Shared/Constants.swift)
#   1. primary    https://api.madfrog.online              (Cloudflare path)
#   2. direct-nl  api.madfrog.online @ 147.45.252.234      (SNI pinned, LE cert)
#   3. direct-spb api.madfrog.online @ 185.218.0.43        (SPB relay)
#   4. decoy-sni  ads.adfox.ru @ 217.198.5.52              (clean-SNI MSK leg)
#   Target: GET /api/v1/mobile/healthcheck — no auth, NO side effects. The auth
#   POSTs ride the SAME host+SNI+TLS, so a leg that reaches healthcheck can carry
#   sign-in and a leg that RSTs/times out cannot. We deliberately do NOT hit
#   /auth/magic/request (it would send a real email and burn the Resend quota).
#
# HONEST LIMITS
#   A datacenter RU IP (MSK) catches RKN SNI-filtering + hard-down — the dominant
#   documented failure. It does NOT see residential/mobile-only throttling (the
#   2026-06-17 audit measured datacenter relays seeing NL/GRA equally reachable).
#   Full residential coverage needs a cheap RU residential probe or a TestFlight
#   device; this is the high-value 80% that needs no human.
#
# INSTALL (on MSK):  crontab -e →
#   */5 * * * * /opt/chameleon/monitoring/ru-auth-healthcheck.sh >> /var/log/ru-auth-healthcheck.log 2>&1
set -uo pipefail

HOST="api.madfrog.online"
PROBE_PATH="/api/v1/mobile/healthcheck"
TIMEOUT="${TIMEOUT:-8}"
NL_IP="147.45.252.234"
SPB_IP="185.218.0.43"
DECOY_SNI="ads.adfox.ru"
DECOY_IP="217.198.5.52"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALERT="${SCRIPT_DIR}/telegram-alert.sh"   # reuse the shared sender if present

# code <curl-args...> → prints the HTTP status (000 on connection failure/RST/timeout)
code() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$@" 2>/dev/null || echo "000"
}

C_PRIMARY=$(code "https://${HOST}${PROBE_PATH}")
C_NL=$(code --resolve "${HOST}:443:${NL_IP}" "https://${HOST}${PROBE_PATH}")
C_SPB=$(code --resolve "${HOST}:443:${SPB_IP}" "https://${HOST}${PROBE_PATH}")
# Decoy leg: connect to MSK with the clean SNI, ask for the real backend via Host.
# -k because the decoy cert is a self-signed leaf the APP pins (decoyCertPin);
# a transport-level reach is what we are testing here, not the pin.
C_DECOY=$(code --resolve "${DECOY_SNI}:443:${DECOY_IP}" -H "Host: ${HOST}" -k "https://${DECOY_SNI}${PROBE_PATH}")

ok=0
for c in "$C_PRIMARY" "$C_NL" "$C_SPB" "$C_DECOY"; do [ "$c" = "200" ] && ok=$((ok+1)); done

LINE="ok=${ok}/4 primary=${C_PRIMARY} direct-nl=${C_NL} direct-spb=${C_SPB} decoy=${C_DECOY}"
echo "[$(date -u +%FT%TZ)] ru-auth ${LINE}"

alert() { [ -x "$ALERT" ] && "$ALERT" "$1" || true; }

# CRITICAL: zero legs reachable → a RU client cannot sign in at all.
if [ "$ok" -eq 0 ]; then
  alert "🔴 RU SIGN-IN DOWN — all 4 auth-transport legs unreachable from $(hostname). ${LINE}"
  exit 2
fi

# DEGRADED: the clean-SNI decoy leg is the RU survivor when RKN RSTs the rest.
# If decoy is down AND the SNI legs are also down, RU sign-in is effectively dead
# even though some non-RU path answered.
if [ "$C_DECOY" != "200" ] && [ "$C_PRIMARY" != "200" ] && [ "$C_NL" != "200" ]; then
  alert "🟡 RU sign-in degraded — decoy + primary + direct-NL all down (RKN SNI-RST?). ${LINE}"
  exit 1
fi

exit 0
