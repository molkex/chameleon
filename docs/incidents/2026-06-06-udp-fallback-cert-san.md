---
title: UDP fallback silently dead — cert missing SAN
date: 2026-06-06
status: resolved
tags: [incident, vpn, udp, hysteria2, tuic, tls, cert]
---
# 2026-06-06 — UDP fallback (Hysteria2/TUIC) silently dead: cert had no SAN

**Severity:** medium (degraded resilience, not an outage) · **Status:** resolved
**Nodes:** NL (147.45.252.234), GRA (54.38.243.162) · **Found via:** user report
("VPN отваливается чаще") → client `singbox.log` analysis.

## Symptom

On every client urltest cycle (~15s) the Hysteria2/TUIC legs were marked
unavailable:

```
outbound/urltest[Auto]: outbound nl-h2-nl2 unavailable: CRYPTO_ERROR 0x12a (local):
  tls: failed to verify certificate: x509: certificate is not valid for any names,
  but wanted to match ads.adfox.ru
outbound/urltest[Auto]: outbound fr-h2-gra1 unavailable: ... ads.adfox.ru
```

So the UDP fallback was 100% dead for everyone. Clients still worked over the
TCP-Reality legs (primary), but had **no UDP escape hatch** when RKN throttles
TCP/Reality — which reads to the user as "loses connection more often."

## Root cause

A regression introduced by **SEC-03** (2026-06-01, commit `4730e6a`). Before
SEC-03 the client used `tls.insecure=true` on the UDP legs, so the server cert's
name/expiry were irrelevant. SEC-03 correctly removed `insecure:true` and instead
**pins** the cert (`tls.certificate`) **and** sets `tls.server_name = <SNI>`
(`ads.adfox.ru`). But the server-side self-signed UDP cert
(`/etc/singbox/server.crt`) was never regenerated — it was still:

```
subject = CN = madfrog.online, O = MadFrog, C = NL
No extensions in certificate          ← no SAN at all
```

Go's TLS stack ignores CN for hostname verification when there is no SAN →
"certificate is not valid for any names". The stale comment in `deploy.sh`
(`client side is tls.insecure=true, so CN/expiry don't matter`) hid the
assumption that SEC-03 had invalidated.

## Key constraint (non-obvious)

`clientconfig.go` pins **one** cert — `engineCfg.UDPCertPEM`, read from the **NL**
backend's `udp_cert_path` — for **every** UDP leg, including `fr-h2-gra1`. So
**all UDP exit nodes must serve the IDENTICAL cert**, and that cert must carry
`SAN=ads.adfox.ru`. A per-node cert (even a correct SAN one) on GRA would fail
with `certificate signed by unknown authority` (pin mismatch).

## Fix

1. NL: backed up `server.crt/server.key`, regenerated a self-signed cert with
   `CN=ads.adfox.ru` + `subjectAltName=DNS:ads.adfox.ru` (10y), `sing-box check`
   OK, `docker restart chameleon` (re-reads `UDPCertPEM` → new pin in served
   client configs), `docker restart singbox` (presents new cert).
2. GRA: copied **NL's** new cert+key into its volume (same pinned cert),
   `sing-box check` OK, `docker restart singbox`.
3. Verified: real Hysteria2 connections from RU residential IPs now succeed on NL
   (e.g. `inbound/hysteria2 ... connection to www.gstatic.com:443`); cert/key
   modulus match on both nodes.

Propagation: existing clients with a cached config keep pinning the OLD cert
(they see `unknown authority` and stay on TCP — no regression) until they refetch
the config; new/reconnecting clients get the working UDP fallback immediately.

## Guardrails added

- `backend/internal/vpn/clientconfig_test.go` → `TestUDPLegsServerNameMatchesSNI`
  locks the client-side contract (every UDP leg `server_name == SNI`).
- `backend/deploy.sh` → fixed the stale comment + added a **SAN guard**: on
  deploy it warns loudly if `server.crt` lacks `SAN=<NODE_SNI>` (does NOT
  auto-regenerate — that would diverge the shared pin).

## How to verify / re-fix

```sh
# inspect the live cert on a node
docker cp singbox:/etc/singbox/server.crt /tmp/c && \
  openssl x509 -in /tmp/c -noout -subject -ext subjectAltName    # want SAN: DNS:ads.adfox.ru

# regenerate (NL is the source of truth), then copy the SAME crt+key to every UDP node
D=/var/lib/docker/volumes/chameleon-singbox-config/_data
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$D/server.key" -out "$D/server.crt" \
  -days 3650 -subj "/CN=ads.adfox.ru/O=MadFrog/C=NL" -addext "subjectAltName=DNS:ads.adfox.ru"
docker exec singbox sing-box check -c /etc/singbox/singbox-config.json
docker restart chameleon            # NL only: re-embed the pin
docker restart singbox              # each UDP node: present the new cert (brief reconnect)
```

Rollback: each node has `server.crt.bak-<ts>` / `server.key.bak-<ts>` next to the
cert; restore + `docker restart singbox`.
