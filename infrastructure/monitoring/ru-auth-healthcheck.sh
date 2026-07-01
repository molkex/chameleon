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

# Return ONLY the HTTP status curl recorded. curl always emits %{http_code} via
# -w (even on a non-zero exit: "000" when no response arrived, or "200" when the
# response came but the transfer closed uncleanly — common on HTTP/2 / slow
# cross-border legs). The old `|| echo 000` APPENDED a second "000" on any non-
# zero exit, producing garbage like "200000"/"000000" that never equals "200" →
# permanent false "degraded" alerts. Capture the value and default only if empty.
code() { local c; c=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$@" 2>/dev/null); printf '%s' "${c:-000}"; }

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

# Classify into a single state + message (severity order: critical > warn > degraded > ok).
state=ok; msg=""
if ! $primary_ok && ! $decoy_ok; then
  state=critical; msg="🔴 RU SIGN-IN DOWN — both auth legs unreachable from $(hostname). ${LINE}"
elif ! $decoy_ok; then
  # both decoy relays down → only CF left, which dies the moment RKN escalates SNI-filtering.
  state=warn; msg="🟡 RU decoy legs DOWN (both relays) — only CF left, fragile under RKN filtering. ${LINE}"
elif [ "$C_DECOY_MSK" != "200" ] || [ "$C_DECOY_SPB" != "200" ]; then
  # one decoy relay down → SPOF is back until it recovers (no user outage yet).
  state=degraded; msg="🟠 RU decoy redundancy degraded — one relay down (SPOF restored). ${LINE}"
fi

# TRANSITION-BASED alerting with flap damping (was: alert EVERY 5-min run →
# Telegram spam). STATE_FILE holds the last ALERTED state (ok or a confirmed
# not-ok). STREAK_FILE counts consecutive not-ok runs; a not-ok state must persist
# $CONFIRM runs (≈10 min) before it pages, so a single transient blip (a one-off
# CF-from-RU timeout, cross-border hiccup) stays silent. We alert on a change of
# confirmed state, re-alert every $REALERT while still not-ok, and send one ✅
# recovery when we return to ok.
STATE_FILE="${SCRIPT_DIR}/.ru-auth.state"
STREAK_FILE="${SCRIPT_DIR}/.ru-auth.streak"
LASTALERT_FILE="${SCRIPT_DIR}/.ru-auth.lastalert"
REALERT="${REALERT:-1800}"   # re-alert every 30 min while not-ok
CONFIRM="${CONFIRM:-2}"      # consecutive not-ok runs required before paging
prev=ok; [ -f "$STATE_FILE" ] && prev=$(cat "$STATE_FILE")
now=$(date +%s); last=0; [ -f "$LASTALERT_FILE" ] && last=$(cat "$LASTALERT_FILE")

cnt=0; [ -f "$STREAK_FILE" ] && cnt=$(cat "$STREAK_FILE")
if [ "$state" = ok ]; then cnt=0; else cnt=$((cnt + 1)); fi
echo "$cnt" > "$STREAK_FILE"

if [ "$state" = ok ]; then
  [ "$prev" != ok ] && alert "✅ RU auth transport recovered. ${LINE}"
  echo ok > "$STATE_FILE"; rm -f "$LASTALERT_FILE"
elif [ "$cnt" -ge "$CONFIRM" ]; then
  if [ "$state" != "$prev" ] || [ $((now - last)) -ge "$REALERT" ]; then
    alert "$msg"
    echo "$now" > "$LASTALERT_FILE"
  fi
  echo "$state" > "$STATE_FILE"
fi
# else: unconfirmed blip (cnt<CONFIRM) — stay silent, leave last alerted state intact.

# Preserve exit-code contract for any external consumer.
case "$state" in
  critical) exit 2 ;;
  warn)     exit 1 ;;
  *)        exit 0 ;;
esac
