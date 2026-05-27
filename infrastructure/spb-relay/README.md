# SPB Relay — nginx config (SprintBox 185.218.0.43)

Reference copy of the production nginx config on the SPB whitelist-bypass
relay. **The live source of truth is on the server**; this directory is a
checked-in mirror so the config doesn't silently revert on a snapshot
restore or VPS reinstall.

## Sync flow

After any production edit:

```bash
sshpass -p "$SPRINTBOX_VPS_PASSWORD" \
  scp root@185.218.0.43:/etc/nginx/conf.d/api-proxy.conf api-proxy.conf
sshpass -p "$SPRINTBOX_VPS_PASSWORD" \
  scp root@185.218.0.43:/etc/nginx/chameleon-stream.conf chameleon-stream.conf
git add infrastructure/spb-relay/ && git commit
```

To re-apply from repo to a fresh VPS:

```bash
sshpass -p "$SPRINTBOX_VPS_PASSWORD" \
  scp api-proxy.conf root@185.218.0.43:/etc/nginx/conf.d/api-proxy.conf
sshpass -p "$SPRINTBOX_VPS_PASSWORD" \
  scp chameleon-stream.conf root@185.218.0.43:/etc/nginx/chameleon-stream.conf
sshpass -p "$SPRINTBOX_VPS_PASSWORD" ssh root@185.218.0.43 \
  'grep -q "/etc/nginx/chameleon-stream.conf" /etc/nginx/nginx.conf || echo "include /etc/nginx/chameleon-stream.conf;" >> /etc/nginx/nginx.conf; nginx -t && nginx -s reload'
```

## Why this VPS exists

SprintHost ASN AS204603 is on the RU whitelist — never blocked by RKN /
Cloudflare-throttling. iOS clients on blocked Cloudflare paths dial this
relay's :2098 (TCP VLESS Reality) or :80 (HTTP API fallback), and nginx
transparently forwards to NL where the real backend / sing-box live.

## Topology

| Port | Role                          | Upstream                |
|------|-------------------------------|-------------------------|
| 80   | HTTP API fallback             | http://147.45.252.234:80 (via api-proxy.conf, Host=api.madfrog.online) |
| 443  | TCP relay (stream)            | 147.45.252.234:443      |
| 2096 | TCP relay (stream, legacy)    | 147.45.252.234:443      |
| 2098 | TCP relay (stream, primary)   | 147.45.252.234:443      |

Originally (pre-2026-05-25) ports 2096 + 443 forwarded to DE; DE retired
so all upstreams now point at NL.

## VPS specs

`Студент` tier: 1 core, 0.5 GB RAM, 7 GB NVMe. **Tight on RAM** — nginx
uses ~200 MB steady, leaves ~190 MB free + 200 MB buff/cache. If memory
pressure grows, upgrade to next tier before installing anything heavier
(e.g. xray, sing-box).

Hostname: `box-900774`, lilac-ubuntu2404-spb-01, Ubuntu 24.04 LTS.
