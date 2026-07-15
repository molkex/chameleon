#!/usr/bin/env bash
# measure-engine-memory.sh — engine-memory (RSS) floor of a generated client config.
#
# Runs the sing-box fork engine HEADLESS (no tun) with a given client config on the
# NL box's fork image and reports peak RSS. This is a FLOOR, not the iOS NE
# phys_footprint: it's Go heap + config + rule-sets, WITHOUT the native
# CFNetwork/NEPacketTunnelFlow/tun buffers that make up ~half the real device number.
# But it's a fast, device-free, repeatable signal for "did my config/rule-set/urltest
# change raise or lower engine memory" — the exact regression class that caused the
# 2026-07-14 OOM incident (4.8 MB refilter) and the urltest cold-start spike.
#
# Reference numbers (2026-07-15, fixture config): emergency no-urltest = ~7.1 MiB;
# with 3 urltest groups = ~12.8 MiB. Compare against these, not against 50 MiB.
#
# Usage:
#   ./measure-engine-memory.sh <client-config.json>
# The config may carry the remote geoip-ru rule_set; the script rewrites it to the
# locally-bundled clients/apple/PacketTunnel/Resources/geoip-ru.srs (what 1.0.35 ships),
# strips tun inbounds + hijack-dns, and substitutes the real server cert for UDP legs.
set -euo pipefail
CFG="${1:?usage: measure-engine-memory.sh <client-config.json>}"
NL=root@147.45.252.234
KEY=~/.ssh/claude-code-ssh-key
SRS="$(cd "$(dirname "$0")/../.." && pwd)/clients/apple/PacketTunnel/Resources/geoip-ru.srs"

scp -q -i "$KEY" "$CFG" "$NL:/tmp/mem_in.json"
scp -q -i "$KEY" "$SRS" "$NL:/tmp/geoip-ru.srs"
ssh -i "$KEY" "$NL" 'bash -s' <<'REMOTE'
set -e
python3 -c "
import json
cert=open('/var/lib/docker/volumes/chameleon-singbox-config/_data/server.crt').read().strip().split(chr(10))
c=json.load(open('/tmp/mem_in.json'))
for o in c.get('outbounds',[]):
    t=o.get('tls')
    if isinstance(t,dict) and 'certificate' in t: t['certificate']=cert
c['inbounds']=[]
c.setdefault('route',{})
c['route']['rules']=[r for r in c['route'].get('rules',[]) if r.get('action')!='hijack-dns']
for r in c['route'].get('rule_set',[]):
    if r.get('tag')=='geoip-ru':
        r['type']='local'; [r.pop(k,None) for k in ('url','download_detour','update_interval')]; r['path']='/geoip-ru.srs'
json.dump(c,open('/tmp/mem_run.json','w'))
print('outbounds:', len(c.get('outbounds',[])), '| urltest-groups:', sum(1 for o in c.get('outbounds',[]) if o.get('type')=='urltest'))
"
IMG=$(docker inspect singbox --format '{{.Config.Image}}')
CID=$(docker run -d --rm -v /tmp/mem_run.json:/c.json -v /tmp/geoip-ru.srs:/geoip-ru.srs --entrypoint sing-box "$IMG" run -c /c.json)
sleep 3
if [ -z "$(docker ps --filter id=$CID --format '{{.Status}}')" ]; then echo "ENGINE FAILED TO START:"; docker logs "$CID" 2>&1 | tail -4; exit 1; fi
peak=0
for i in $(seq 1 8); do
  n=$(docker stats --no-stream --format '{{.MemUsage}}' "$CID" 2>/dev/null | grep -oE '^[0-9.]+')
  [ -n "$n" ] && awk "BEGIN{exit !($n>$peak)}" && peak=$n
  sleep 2
done
docker stop "$CID" >/dev/null 2>&1 || true
echo "=== engine peak RSS: ${peak} MiB (floor — add ~2x for the iOS NE phys_footprint) ==="
REMOTE
