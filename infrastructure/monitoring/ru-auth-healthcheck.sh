#!/usr/bin/env bash
# ============================================================
#  RU-vantage auth-transport healthcheck   (PRODUCT-MATURITY-LOOP, 2026-06-21)
# ============================================================
# WHY: sign-in (email/Google/Apple) fails intermittently from Russian IPs and
# works from non-RU IPs. It is ONE transport problem, not three auth bugs: RKN's
# TSPU SNI-filters `api.madfrog.online` and RSTs the TLS handshake, so every leg
# that presents that SNI can die at once. Server logs at NL look clean because
# the requests never arrive — so the ONLY way to see it is from a RU vantage.
# Run this on the MSK relay (a real RU IP) on a cron to know, every few minutes,
# whether a client in Russia can reach auth — instead of finding out from users.
#
# GROUND TRUTH measured 2026-06-21 (drives the leg model below):
#   * NL:443 is sing-box Reality (presents a *.adfox.ru cert); there is NO
#     api.madfrog.online cert on NL, and the API is on :80 only. So the app's
#     direct-IP auth legs (IP:443, SNI=api.madfrog.online, chain-vs-SNI verify)
#     are DEAD — wrong cert — AND that SNI is RKN-filterable regardless of IP.
#   * The real RU auth transport is therefore: primary (Cloudflare) + the
#     clean-SNI decoy leg (ads.adfox.ru -> MSK, RKN-safe). The decoy is the only
#     leg that survives SNI-filtering, so it is the one that must never be down.
#
# Probe target: GET /api/v1/mobile/healthcheck (no auth, no side effects). The
# auth POSTs ride the same host+SNI+TLS, so reachability here == sign-in can land.
# We do NOT hit /auth/magic/request (it would send a real email, burning quota).
#
# LIMIT: a datacenter RU IP catches SNI-filtering + hard-down (the dominant
# documented failure) but not residential/mobile-only throttling. Full coverage
# needs client-side per-leg telemetry (next build) or a residential probe.
#
# INSTALL (MSK):  */5 * * * * /opt/chameleon/monitoring/ru-auth-healthcheck.sh >> /var/log/ru-auth-healthcheck.log 2>&1
set -uo pipefail

HOST="api.madfrog.online"
PROBE_PATH="/api/v1/mobile/healthcheck"
TIMEOUT="${TIMEOUT:-8}"
DECOY_SNI="ads.adfox.ru"
DECOY_IP="217.198.5.52"
NL_IP="147.45.252.234"
SPB_IP="185.218.0.43"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALERT="${SCRIPT_DIR}/telegram-alert.sh"

code() { curl -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$@" 2>/dev/null || echo "000"; }

# --- the REAL RU auth-transport legs ---
C_PRIMARY=$(code "https://${HOST}${PROBE_PATH}")                                              # Cloudflare (filterable SNI)
# clean-SNI decoy legs (RKN survivors) — MSK:443 + SPB:8443 (RU-DECOY-2ND, no SPOF)
C_DECOY_MSK=$(code --resolve "${DECOY_SNI}:443:${DECOY_IP}" -H "Host: ${HOST}" -k "https://${DECOY_SNI}${PROBE_PATH}")
C_DECOY_SPB=$(code --resolve "${DECOY_SNI}:8443:${SPB_IP}" -H "Host: ${HOST}" -k "https://${DECOY_SNI}:8443${PROBE_PATH}")

LINE="primary=${C_PRIMARY} decoy_msk=${C_DECOY_MSK} decoy_spb=${C_DECOY_SPB}"
echo "[$(date -u +%FT%TZ)] ru-auth ${LINE}"

alert() { [ -x "$ALERT" ] && "$ALERT" "$1" || true; }

primary_ok=false; [ "$C_PRIMARY" = "200" ] && primary_ok=true
# decoy transport is healthy if EITHER relay answers (2nd leg removes the SPOF)
decoy_ok=false;   { [ "$C_DECOY_MSK" = "200" ] || [ "$C_DECOY_SPB" = "200" ]; } && decoy_ok=true

# CRITICAL: no RU auth transport at all.
if ! $primary_ok && ! $decoy_ok; then
  alert "🔴 RU SIGN-IN DOWN — both auth legs unreachable from $(hostname). ${LINE}"
  exit 2
fi
# WARN: both decoy relays are down → only CF left, which dies the moment RKN
# escalates SNI-filtering. This is the leg whose loss precedes user outage.
if ! $decoy_ok; then
  alert "🟡 RU decoy legs DOWN (both relays) — only CF left, fragile under RKN filtering. ${LINE}"
  exit 1
fi
# DEGRADED: one decoy relay down → SPOF is back until it recovers (no outage yet).
if [ "$C_DECOY_MSK" != "200" ] || [ "$C_DECOY_SPB" != "200" ]; then
  alert "🟠 RU decoy redundancy degraded — one relay down (SPOF restored). ${LINE}"
  exit 0
fi
exit 0
