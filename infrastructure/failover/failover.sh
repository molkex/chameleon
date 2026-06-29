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
MSK_CONF="/etc/nginx/sites-available/api.madfrog.online"
MSK_DECOY="/etc/nginx/sites-available/decoy-adfox"
EXITS=("54.38.243.162" "217.182.74.70")   # GRA, WAW exit user-api boxes (ufw :15380)

# ── node registry ────────────────────────────────────────────────────────────
node_cfg() {
  case "$1" in
    waw)
      SSH="debian@217.182.74.70"; SUDO="sudo "; IP="217.182.74.70"
      PG="chameleon-postgres-standby"; CHAM="chameleon-failover"
      MSK_TARGET="217.182.74.70:8000" ;;     # WAW backend serves chameleon directly on :8000
    nl)
      SSH="root@147.45.252.234"; SUDO=""; IP="147.45.252.234"
      PG="chameleon-postgres"; CHAM="chameleon"
      MSK_TARGET="147.45.252.234:80" ;;      # NL backend fronted by nginx on :80
    *) echo "unknown node: $1 (use waw|nl)"; exit 2 ;;
  esac
}
rexec() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=12 "$1" "$2" 2>/dev/null; }
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
if [ "$CUR" != "$TARGET" ] && [ "$CUR" != unknown* ]; then
  OLD="$CUR"; node_cfg "$OLD"; OLD_SSH="$SSH"; OLD_SUDO="$SUDO"; OLD_CHAM="$CHAM"
  node_cfg "$TARGET"   # restore target vars
  say "fencing old primary $OLD: stop chameleon (no more writes)"
  rexec "$OLD_SSH" "${OLD_SUDO}docker stop $OLD_CHAM ${OLD_SUDO}docker stop chameleon-nginx 2>/dev/null" || true
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

# 3. START target chameleon + wait healthy
say "starting $TARGET chameleon ($CHAM)"
rexec "$SSH" "${SUDO}docker start $CHAM" || die "could not start $CHAM"
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

# 5. FLIP MSK ingress → target
say "flipping MSK upstream → $MSK_TARGET"
rexec "$MSK_SSH" "ts=\$(date +%s); cp $MSK_CONF $MSK_CONF.bak-failover-\$ts; cp $MSK_DECOY $MSK_DECOY.bak-failover-\$ts 2>/dev/null; \
  sed -i -E 's#(147.45.252.234:80|217.182.74.70:8000)#$MSK_TARGET#g' $MSK_CONF $MSK_DECOY; \
  nginx -t && systemctl reload nginx && echo RELOADED" | tail -1

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
