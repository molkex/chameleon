#!/usr/bin/env bash
# ============================================================
#  Rebuild a node as a streaming REPLICA of the current primary
#  (failback / restore-redundancy after a failover). Design: ADR 0013.
# ============================================================
# Codifies the 2026-06-29 "make NL a replica of WAW" procedure, incl. the
# gotcha that cost an hour: a BRIDGE-networked postgres container cannot reach a
# host-loopback SSH tunnel — the tunnel must bind to the docker GATEWAY ip and
# the node's ufw must allow the docker subnet → the tunnel port.
#
# Transport = SSH tunnel (no public 5432; WAL = all data).
#
# Usage:  ./rebuild-replica.sh <replica-node> <primary-node>
#   e.g.  ./rebuild-replica.sh nl waw
# DESTRUCTIVE: wipes the replica node's postgres data (the primary is the truth).
set -uo pipefail
KEY="${SSH_KEY:-$HOME/.ssh/claude-code-ssh-key}"

node() { case "$1" in
  waw) SSH="debian@217.182.74.70"; SUDO="sudo "; IP="217.182.74.70"; PG="chameleon-postgres-standby" ;;
  nl)  SSH="root@147.45.252.234";  SUDO="";      IP="147.45.252.234"; PG="chameleon-postgres" ;;
  *) echo "unknown node $1"; exit 2 ;; esac ; }
rx() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$1" "$2"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo ">>> $*"; }

REP="${1:?replica node}"; PRI="${2:?primary node}"
node "$REP"; R_SSH="$SSH"; R_SUDO="$SUDO"; R_PG="$PG"
node "$PRI"; P_SSH="$SSH"; P_SUDO="$SUDO"; P_IP="$IP"; P_PG="$PG"
SLOT="${REP}_standby"
read -r -p "WIPE $REP postgres and rebuild as replica of $PRI? type 'yes': " ok; [ "$ok" = yes ] || die aborted

# 1. primary: ensure replicator role + a slot for this replica
say "primary $PRI: ensure replicator role + slot $SLOT"
rx "$P_SSH" "${P_SUDO}docker exec $P_PG psql -U chameleon -d chameleon -tAc \"select 1 from pg_roles where rolname='replicator'\" | grep -q 1 || ${P_SUDO}docker exec $P_PG psql -U chameleon -d chameleon -c \"CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '\${CHAMELEON_PG_REPLICATOR_PASSWORD:-changeme}'\""
rx "$P_SSH" "${P_SUDO}docker exec $P_PG psql -U chameleon -d chameleon -tAc \"SELECT pg_create_physical_replication_slot('$SLOT')\" 2>/dev/null; true"

# 2. replica: SSH key → primary, restricted to forward :5432
say "replica $REP: key + reverse tunnel to $PRI"
RPUB=$(rx "$R_SSH" "[ -f ~/.ssh/repl_tunnel ] || ssh-keygen -t ed25519 -f ~/.ssh/repl_tunnel -N '' -C '$REP-pg-replica' >/dev/null 2>&1; cat ~/.ssh/repl_tunnel.pub")
rx "$P_SSH" "grep -q '$REP-pg-replica' ~/.ssh/authorized_keys 2>/dev/null || echo 'restrict,port-forwarding,permitopen=\"127.0.0.1:5432\" $RPUB' >> ~/.ssh/authorized_keys"

# 3. replica: discover its postgres docker GATEWAY (bridge containers can't use host loopback)
GW=$(rx "$R_SSH" "${R_SUDO}docker inspect $R_PG --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}'")
[ -n "$GW" ] || GW="127.0.0.1"
say "replica $REP postgres gateway = $GW"

# 4. replica: autossh tunnel bound to the gateway (GatewayPorts) + ufw for the docker subnet
say "replica $REP: autossh tunnel (bind $GW:15432) + ufw for docker subnet"
SUBNET="$(echo "$GW" | sed -E 's/\.[0-9]+$/.0\/16/')"
rx "$R_SSH" "${R_SUDO}bash -c '
  command -v autossh >/dev/null || apt-get install -y autossh >/dev/null 2>&1
  cat > /etc/systemd/system/pg-tunnel-${PRI}.service <<EOF
[Unit]
Description=autossh tunnel ${REP}->${PRI} postgres replica
After=network-online.target
Wants=network-online.target
[Service]
Environment=AUTOSSH_GATETIME=0
ExecStart=/usr/bin/autossh -M 0 -N -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new -o GatewayPorts=yes -i ${R_HOME:-/root}/.ssh/repl_tunnel -L 0.0.0.0:15432:127.0.0.1:5432 ${P_SSH}
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload && systemctl enable --now pg-tunnel-${PRI}.service
  command -v ufw >/dev/null && ufw allow from ${SUBNET} to any port 15432 proto tcp >/dev/null 2>&1
  sleep 3'"

# 5. replica: stop pg, wipe, basebackup via the tunnel (gateway), fix conninfo, start
say "replica $REP: stop + wipe + pg_basebackup from $PRI (slot $SLOT)"
VOL=$(rx "$R_SSH" "${R_SUDO}docker inspect $R_PG --format '{{range .Mounts}}{{if eq .Destination \"/var/lib/postgresql/data\"}}{{.Name}}{{end}}{{end}}'")
IMG=$(rx "$R_SSH" "${R_SUDO}docker inspect $R_PG --format '{{.Config.Image}}'")
rx "$R_SSH" "${R_SUDO}docker stop $R_PG >/dev/null 2>&1
  ${R_SUDO}docker run --rm -v $VOL:/d alpine sh -c 'rm -rf /d/* /d/.[!.]* 2>/dev/null'
  ${R_SUDO}docker run --rm --network host -v $VOL:/data $IMG bash -c 'pg_basebackup -h $GW -p 15432 -U replicator -D /data -R -S $SLOT -X stream -P 2>&1 | tail -2 && chown -R 70:70 /data'
  ${R_SUDO}docker exec -i $R_PG true 2>/dev/null; ${R_SUDO}docker run --rm -v $VOL:/d alpine sh -c \"sed -i 's#host=127.0.0.1 port=15432#host=$GW port=15432#g' /d/postgresql.auto.conf\"
  ${R_SUDO}docker start $R_PG >/dev/null 2>&1; sleep 6
  echo replica_in_recovery=\$(${R_SUDO}docker exec $R_PG psql -U chameleon -d chameleon -tAc 'select pg_is_in_recovery()')" | tail -3

# 6. verify streaming from the primary side
sleep 3
say "verify: $PRI pg_stat_replication"
rx "$P_SSH" "${P_SUDO}docker exec $P_PG psql -U chameleon -d chameleon -x -c \"select application_name,state,sync_state,replay_lag from pg_stat_replication\" | tail -5"
echo "✅ $REP rebuilt as replica of $PRI (verify state=streaming + lag above)."
