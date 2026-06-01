---
title: Debug iOS/macOS client + VPN tunnel
date: 2026-06-01
status: active
tags: [ios, macos, vpn, singbox, debug, playbook]
---

# Debug iOS/macOS + VPN

Reusable techniques for "VPN says connected but no traffic", config staleness,
server-switch oddities. Resolved one-off incidents live in
[`../incidents/`](../incidents/) — this is the toolkit, not the history.

## Where client logs + cached config live

Both the main app and the PacketTunnel extension are separate processes that
share the App Group container `group.com.madfrog.vpn`:

```
~/Library/Group Containers/group.com.madfrog.vpn/
```

- `singbox.log` — tunnel-side logs (the extension; main-app logs are separate).
- cached client config JSON — its **mtime = timestamp of the last successful
  config fetch** from the backend. A stale mtime means the app has been serving
  a cached config and `/api/v1/mobile/config` fetches are failing.

⚠️ **iOS-on-Mac log blindness:** host `log show` does NOT see logs from an iOS
app running on Apple Silicon Mac. Read the files in the Group Container above,
or use the in-app log viewer. For a real iPhone, stream live with
`idevicesyslog -m "MadFrogVPN" -m "PacketTunnel"` or
`xcrun devicectl device process launch --console …`.

Fastest path: in-app ladybug icon → Copy logs → paste.

## Gate every sing-box config change with `check`

Before testing on any device, on the server that owns the config:

```bash
sing-box check -c /etc/singbox/singbox-config.json
```

Fix **all** format errors at once (don't iterate field-by-field). sing-box 1.13
rules: `{"action":"sniff"}` first, then `{"protocol":"dns","action":"hijack-dns"}`;
DNS servers go direct by default (no `detour:"direct"`); no `inet4_address`,
`strict_route`, or `dns.fakeip` block (use a `type:"fakeip"` DNS server).

## clash / v2ray API quirks

- **No clash API on iOS.** `ConfigSanitizer.swift` strips
  `experimental.clash_api` — the NE sandbox can't bind a TCP socket, so any HTTP
  to `127.0.0.1:909x` is Connection Refused. Switch outbounds / routing modes via
  `LibboxCommandClient.selectOutbound(groupTag:outboundTag:)` over the unix
  `command.sock`, not the clash HTTP API.
- **clash API is a UI snapshot, not accounting.** `/connections` shows only
  *currently open* TCP streams; VLESS multiplexes short-lived conns so per-user
  byte deltas read as 0. Persistent per-user traffic comes from the v2ray_api
  gRPC StatsService, not clash.
- **The main app must call `LibboxSetup`** with the same base/working/temp paths
  as the extension, or `CommandClient` never connects → server-switch falls back
  to a full teardown (multi-second UI freeze).

## Symptom → where to look

| Symptom | Likely cause / where to look |
|---|---|
| Connected, but no traffic | Extension `singbox.log` in Group Container; check route-rule order (`sniff` first) and QUIC reject (`no_drop:true`). |
| Server-switch UI lies / IP unchanged | `selectOutbound` only re-routes *new* streams — must follow with `closeConnections()`. Read live `commandClient.selectedServer`, not `configStore.selectedServerTag`. |
| Config never updates | cached-config mtime in Group Container is old → `/api/v1/mobile/config` fetch failing (backend down, or `reality_private_key` wiped → restart loop). |
| Exit IP geolocates wrong (e.g. NL reads as RU) | GeoIP DBs mis-classify Timeweb as RU. Verify with `ipleak.net`/`ifconfig.me`, not whoer/2ip. NL egress is source-bound to a clean IP. |
| Widget state diverges from app | authoritative state is written by the extension when sing-box actually starts; don't trust optimistic widget writes. |
| RU users can't reach exit at all | check it's not an ASN-level block; confirm SPB/MSK relay legs and `ufw` ports. |

## Useful one-liners

```bash
# Reality keypair sanity (priv→pub must match DB/config)
docker run --rm teddysun/xray xray x25519 -i <private_key>

# Per-user traffic actually recording? (NL)
docker exec chameleon-postgres psql -U chameleon -d chameleon -c \
  "SELECT vpn_username, download_traffic, timestamp FROM traffic_snapshots ORDER BY timestamp DESC LIMIT 5;"
```
