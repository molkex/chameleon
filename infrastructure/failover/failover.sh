#!/usr/bin/env bash
# ============================================================
#  Chameleon control-plane FAILOVER — promote a node to primary
#  Design: docs/decisions/0013-ha-failover-msk-ingress.md
#  Runbook: docs/playbooks/nl-failover.md
# ============================================================
# Codifies the procedure proven by hand during the 2026-06-29 NL outage:
#   fence old primary → promote target postgres → start target chameleon →
#   flip MSK upstream → repoint exit user-api ufw → verify.
#
# "Who is primary" == "where the MSK nginx upstream points" (single ingress =
# source of truth). Exactly ONE chameleon runs at a time (the only DB writer) →
# no split-brain. The old primary is rebuilt as a replica afterwards (separate
# step: failback / rebuild-replica.sh).
#
# Usage:
#   ./failover.sh <waw|nl> [--yes]
#   ./failover.sh status            # show current primary + replication
#
# SAFETY: destructive (promotes a DB, flips live RU-API ingress). Requires an
# interactive "yes" unless --yes. DRILL in a low-traffic window before relying.
set -uo pipefail

KEY="${SSH_KEY:-$HOME/.ssh/claude-code-ssh-key}"
MSK_SSH="root@217.198.5.52"
MSK_IP="217.198.5.52"
MSK_CONF="/etc/nginx/sites-available/api.madfrog.online"
MSK_DECOY="/etc/nginx/sites-available/decoy-adfox"
EXITS=("217.182.74.70" "147.45.252.234")   # WAW, NL(nl2) exit user-api boxes (ufw :15380).
  # GRA (54.38.243.162) removed 2026-07-11 — France exit decommissioned (zero real
  # usage in 14d telemetry), sing-box stopped, DB rows deactivated. VPS itself pending
  # manual auto-renew-off in the OVH panel (API key has no write grant), expires
  # 2026-08-01. nl2 reactivated as a live fallback 2026-07-11 — was missing here since
  # the 2026-06-29 failover, so a future failover would not have repointed its
  # user-api ufw to the new primary.

# SPB second decoy leg (RU-DECOY-2ND): password-auth box, NOT on the key. Needs
# SPRINTBOX_VPS_PASSWORD (from ~/.secrets.env) + sshpass; if either is missing the
# SPB steps SKIP cleanly (best-effort) and warn — MSK decoy alone still serves.
SPB_SSH="root@185.218.0.43"
SPB_IP="185.218.0.43"
SPB_DECOY="/etc/nginx/conf.d/decoy-adfox.conf"
[ -z "${SPRINTBOX_VPS_PASSWORD:-}" ] && [ -f "$HOME/.secrets.env" ] && . "$HOME/.secrets.env" 2>/dev/null
spb_exec() {  # best-effort; returns non-zero (and warns) if SPB is unreachable by password
  [ -n "${SPRINTBOX_VPS_PASSWORD:-}" ] || { echo "  (skip SPB: SPRINTBOX_VPS_PASSWORD not set)"; return 1; }
  command -v sshpass >/dev/null 2>&1 || { echo "  (skip SPB: sshpass not installed)"; return 1; }
  sshpass -p "$SPRINTBOX_VPS_PASSWORD" ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=12 "$SPB_SSH" "$1" 2>/dev/null
}

# ── node registry ────────────────────────────────────────────────────────────
node_cfg() {
  case "$1" in
    waw)
      SSH="debian@217.182.74.70"; SUDO="sudo "; IP="217.182.74.70"
      PG="chameleon-postgres-standby"; CHAM="chameleon-failover"; NGINX="chameleon-nginx"
      MSK_TARGET="217.182.74.70:8000" ;;     # MSK/API traffic hits chameleon directly on :8000
        # (nginx isn't in the health-check path), BUT chameleon-nginx is still WAW's WEB
        # frontend (madfrog.online via Cloudflare, since 2026-07-01) and MUST be started too —
        # found the hard way 2026-07-11: the fence step stops chameleon-nginx on ANY old
        # primary, and leaving NGINX="" here meant a WAW failback silently left the web
        # frontend down (API/VPN fine, madfrog.online 521 via Cloudflare) until an external
        # monitor caught it ~1 hour later. Verify BOTH api.madfrog.online AND madfrog.online
        # after any failover — the API health check alone does not cover this.
    nl)
      SSH="root@147.45.252.234"; SUDO=""; IP="147.45.252.234"
      PG="chameleon-postgres"; CHAM="chameleon"; NGINX="chameleon-nginx"
      MSK_TARGET="147.45.252.234:80" ;;      # NL backend fronted by nginx on :80 — the health
        # check below hits this port, so nginx must be started too, not just chameleon
        # (found 2026-07-11 during drill prep: this step silently only started chameleon,
        # so failover.sh nl would hang at step 3 waiting on a health check nginx never served)
    *) echo "unknown node: $1 (use waw|nl)"; exit 2 ;;
  esac
}
rexec() { ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=12 "$1" "$2" 2>/dev/null; }
say()  { echo ">>> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

current_primary() {  # read from the live MSK upstream
  local up; up=$(rexec "$MSK_SSH" "grep -m1 proxy_pass $MSK_CONF | grep -oE '[0-9.]+:[0-9]+'")
  case "$up" in 217.182.74.70:*) echo waw ;; 147.45.252.234:*) echo nl ;; *) echo "unknown($up)" ;; esac
}

# ── status ───────────────────────────────────────────────────────────────────
if [ "${1:-}" = "status" ]; then
  echo "current primary (per MSK upstream): $(current_primary)"
  echo "api.madfrog.online/health: $(curl -s -m8 -o /dev/null -w '%{http_code}' https://api.madfrog.online/health)"
  exit 0
fi

TARGET="${1:-}"; [ -n "$TARGET" ] || { echo "usage: $0 <waw|nl> [--yes] | status"; exit 2; }
node_cfg "$TARGET"
CUR=$(current_primary)
say "current primary = $CUR ; failing over to = $TARGET"
[ "$CUR" = "$TARGET" ] && { say "already primary — checking it's healthy"; }

if [ "${2:-}" != "--yes" ]; then
  read -r -p "Promote '$TARGET' to PRIMARY and flip live ingress? type 'yes': " ok
  [ "$ok" = "yes" ] || die "aborted"
fi

# 1. FENCE old primary (best-effort; it may be unreachable — that's fine, MSK starves it)
if [ "$CUR" != "$TARGET" ] && [[ "$CUR" != unknown* ]]; then
  # NOTE (fixed 2026-07-11): the old `[ "$CUR" != unknown* ]` used POSIX `[ ]`, which does
  # NOT glob-match — `unknown*` only matches literally, so an unreadable-MSK "unknown(...)"
  # state fell through to node_cfg("unknown(...)") below and died with a confusing
  # "unknown node" error instead of skipping the fence with a clear message. `[[ ]]` (bash)
  # does pattern-match on the right side of `!=`, which is what was actually intended.
  OLD="$CUR"; node_cfg "$OLD"; OLD_SSH="$SSH"; OLD_SUDO="$SUDO"; OLD_CHAM="$CHAM"
  node_cfg "$TARGET"   # restore target vars
  say "fencing old primary $OLD: stop chameleon (no more writes)"
  # NOTE (fixed 2026-07-11): this used to be one un-separated string —
  # "docker stop $OLD_CHAM docker stop chameleon-nginx" — which `docker stop` happened to
  # parse as 4 container-name arguments (silently erroring, harmlessly, on the literal
  # "docker" and "stop"). Explicit `;` makes it two real commands instead of an accident.
  rexec "$OLD_SSH" "${OLD_SUDO}docker stop $OLD_CHAM; ${OLD_SUDO}docker stop chameleon-nginx" || true
fi

# 2. PROMOTE target postgres (if it's a replica)
say "promoting $TARGET postgres ($PG) if in recovery"
INREC=$(rexec "$SSH" "${SUDO}docker exec $PG psql -U chameleon -d chameleon -tAc 'select pg_is_in_recovery()'")
if [ "$INREC" = "t" ]; then
  rexec "$SSH" "${SUDO}docker exec $PG psql -U chameleon -d chameleon -c 'select pg_promote()'" || die "promote failed"
  sleep 3
fi
INREC=$(rexec "$SSH" "${SUDO}docker exec $PG psql -U chameleon -d chameleon -tAc 'select pg_is_in_recovery()'")
[ "$INREC" = "f" ] || die "$TARGET postgres still in recovery — not writable"
say "$TARGET postgres is PRIMARY (writable). users=$(rexec "$SSH" "${SUDO}docker exec $PG psql -U chameleon -d chameleon -tAc 'select count(*) from users'")"

# 3. START target chameleon (+ nginx, if this node fronts it with one) + wait healthy
say "starting $TARGET chameleon ($CHAM)"
rexec "$SSH" "${SUDO}docker start $CHAM" || die "could not start $CHAM"
if [ -n "$NGINX" ]; then
  say "starting $TARGET nginx ($NGINX) — the health check below hits nginx's port, not chameleon's"
  rexec "$SSH" "${SUDO}docker start $NGINX" || die "could not start $NGINX"
fi
for i in $(seq 1 15); do
  hc=$(rexec "$SSH" "curl -s -m4 -o /dev/null -w '%{http_code}' http://127.0.0.1:${MSK_TARGET##*:}/health")
  [ "$hc" = "200" ] && { say "$TARGET chameleon healthy"; break; }
  sleep 2; [ "$i" = 15 ] && die "$TARGET chameleon did not become healthy"
done

# 4. REPOINT exit user-api ufw to the new primary ($IP), remove the other backend
say "repointing exit user-api ufw → $IP"
for ex in "${EXITS[@]}"; do
  [ "$ex" = "$IP" ] && continue
  rexec "debian@$ex" "sudo ufw allow from $IP to any port 15380 proto tcp; for o in 147.45.252.234 217.182.74.70; do [ \$o = $IP ] || sudo ufw delete allow from \$o to any port 15380 proto tcp 2>/dev/null; done" >/dev/null 2>&1 || true
done

# 4b. OPEN new-primary backend port to BOTH RU relays (MSK + SPB).
#     WAW:8000 is ufw-whitelisted per-relay; without this the relay decoy 502s
#     (exactly the SPB 502 seen post the 2026-06-29 hand-failover). NL:80 is
#     public so this is a harmless no-op there.
PORT="${MSK_TARGET##*:}"
say "allowing RU relays (MSK $MSK_IP, SPB $SPB_IP) → new primary :$PORT"
rexec "$SSH" "${SUDO}ufw allow from $MSK_IP to any port $PORT proto tcp; ${SUDO}ufw allow from $SPB_IP to any port $PORT proto tcp" >/dev/null 2>&1 || true

# 5. FLIP MSK ingress → target
say "flipping MSK upstream → $MSK_TARGET"
rexec "$MSK_SSH" "ts=\$(date +%s); cp $MSK_CONF $MSK_CONF.bak-failover-\$ts; cp $MSK_DECOY $MSK_DECOY.bak-failover-\$ts 2>/dev/null; \
  sed -i -E 's#(147.45.252.234:80|217.182.74.70:8000)#$MSK_TARGET#g' $MSK_CONF $MSK_DECOY; \
  nginx -t && systemctl reload nginx && echo RELOADED" | tail -1

# 5b. FLIP SPB second decoy leg → target (best-effort; password-auth box).
say "flipping SPB decoy upstream → $MSK_TARGET"
spb_exec "ts=\$(date +%s); cp $SPB_DECOY $SPB_DECOY.bak-failover-\$ts 2>/dev/null; \
  sed -i -E 's#(147.45.252.234:80|217.182.74.70:8000)#$MSK_TARGET#g' $SPB_DECOY; \
  nginx -t && systemctl reload nginx && echo SPB_RELOADED" | tail -1

# 6. VERIFY
sleep 2
HC=$(curl -s -m8 -o /dev/null -w '%{http_code}' https://api.madfrog.online/health)
say "api.madfrog.online/health = $HC  (primary now: $(current_primary))"
[ "$HC" = "200" ] || die "VERIFY FAILED — api not 200. Check MSK + $TARGET chameleon."

cat <<DONE

✅ FAILOVER to $TARGET complete + verified.
NEXT (restore redundancy): rebuild the old primary as a REPLICA of $TARGET —
see infrastructure/failover/rebuild-replica.sh + playbooks/nl-failover.md.
(Optional) flip Cloudflare apex origin → $IP for the admin SPA.
DONE
