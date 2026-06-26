---
title: RU-no-VPN sign-in fails — RKN SNI-filters api.madfrog.online
date: 2026-06-17
status: resolved
tags: [incident, ru, sni, rkn, auth, ios]
---
# 2026-06-17 — RU-no-VPN sign-in fails: RKN SNI-filters api.madfrog.online

**Severity:** high (core flow — users could not sign in without already having a VPN on)
**Status:** fixed in iOS build 120 (RU-DECOY-SNI) + MSK relay nginx decoy block

## Symptom

Real-device reports over several TestFlight builds (116→119): on a RU network
*without* a VPN, sign-in (Apple/Google/Email) intermittently failed with
`Не удалось войти … (network: all paths failed)` — on both Wi-Fi and LTE. With
*any* VPN already running, sign-in worked every time. "Worked once then stopped"
was the recurring pattern.

## Measurement (what disproved the easy theories)

NL backend access logs for the affected user (`user_id 12351`, apple) showed the
auth POST **arriving and returning 200** at the exact moment the phone displayed
"all paths failed":

```
16:58:25  POST /api/mobile/auth/apple  status=200  ip=212.233.85.55  ua=MadFrogVPN/119 CFNetwork…
```

So the request reached the server and the server answered 200 — but the response
never made it back to the device. Both hedged legs (CFNetwork primary + the
direct-IP SNI-spoof legs) failed together on the same attempt.

All four race legs probe healthy from a non-RU vantage (MSK/SPB/NL `/health` =
200, ~0.5 s). The failure is **only** visible from the client's RU network.

## Root cause

Every race leg in `dataWithFallback` presents the **same TLS SNI =
`api.madfrog.online`** (primary via DNS, direct-IP legs via
`AppConfig.baseURLHost`). RKN's TSPU SNI-filters that hostname and RST's the
connection — sometimes on the ClientHello, sometimes mid-response (hence
"server logged 200, client got nothing"). Because all legs carry the filtered
SNI, they die together → `all paths failed`. A VPN hides the SNI inside the
tunnel, which is why VPN-on always worked.

`AUTH-RETRY` (build 119, 3× retry on transient "all paths failed") did **not**
fix it: the SNI block is systemic, not a brief blip.

## Fix (build 120 — RU-DECOY-SNI)

Give sign-in a leg that rides the **same camouflage SNI the VPN data-plane
already uses successfully**: `ads.adfox.ru` (Yandex adfox — RKN doesn't filter
its own ad domain).

- **MSK relay** (`217.198.5.52`, domestic RU IP): new nginx server block
  `server_name ads.adfox.ru` with a self-signed cert
  (`/etc/nginx/decoy/adfox.crt`), proxying to NL exactly like the
  `api.madfrog.online` front (forces `Host: madfrog.online` upstream). The real
  api front is untouched.
- **iOS client**: `DirectConnection.request(…, pinnedCertSHA256:)` adds a
  cert-**pinning** mode (leaf DER SHA-256). `dataWithFallback` adds a "decoy"
  leg at T+150ms — SNI `ads.adfox.ru` → MSK, pinned cert — for every sensitive
  request (auth/refresh) and any RU/unknown-region request. Pinning also means
  a network that SNI-hijacks `ads.adfox.ru` to the *real* adfox (valid
  GlobalSign cert) is rejected, so credentials never leak.

Region gating note: the decoy leg is on for **all** regions when `sensitive`,
because many RU users set their App Store / device region to US to install the
app — region is not a reliable "is this user in RU" signal for the auth path.

## Verify

```bash
# server-side, from MSK localhost (decoy block routes to NL):
echo | openssl s_client -connect 127.0.0.1:443 -servername ads.adfox.ru | openssl x509 -noout -subject
#   -> subject=CN = ads.adfox.ru  (our self-signed)
curl -sk --resolve ads.adfox.ru:443:127.0.0.1 https://ads.adfox.ru/health        # 200
curl -sk --resolve ads.adfox.ru:443:127.0.0.1 -X POST https://ads.adfox.ru/api/mobile/auth/apple -d '{}'  # 400 (live backend)
```

Cert pin (`AppConfig.decoyCertPin`):
`openssl x509 -in /etc/nginx/decoy/adfox.crt -outform DER | openssl dgst -sha256`.
The cert is valid 10 years; if MSK is re-provisioned, regenerate and update the
pin constant + ship a client build.

## Gotcha discovered

From *some* networks (observed from the dev Mac), a plain dial to MSK:443 with
SNI `ads.adfox.ru` is transparently SNI-routed to the **real** adfox (returns a
GlobalSign `*.adfox.ru` cert, HTTP 400). The pin correctly rejects that path, so
the leg degrades gracefully to the other legs — no regression, and on the
networks where the VPN's `ads.adfox.ru` camouflage works (the user's), the decoy
leg reaches MSK and wins.

## Follow-up: build 121 — RU-DECOY-FIRST (the 2nd-sign-in hang)

b120 fixed the *first* sign-in but the user reported the **second** attempt hung
("1 раз спокойно заходит … выхожу, ещё раз — зависание"). MSK access log for the
first login showed why:

```
37.113.209.81 POST /api/mobile/auth/apple 200 648  "MadFrog-iOS"               <- decoy leg won
37.113.209.81 POST /api/mobile/auth/apple 499 0    "MadFrogVPN/120 CFNetwork…" <- primary, api SNI, client-cancelled
```

The decoy won, but the **primary leg still opened a TLS connection with SNI
`api.madfrog.online`** (logged 499 = client closed after the decoy won). That
ClientHello alone is enough for RKN's TSPU to flag the client→relay flow. The
first sign-in slips through; the TSPU then escalates and RSTs *everything* to the
relay — so the second sign-in's decoy is also killed and nothing reaches the
server (no 2nd-attempt log on NL *or* MSK).

Fix (b121): hold the filtered-SNI legs (primary + direct-IP) `poisonHoldMs =
2000ms` behind the decoy on sensitive auth; the decoy leads at T+0. A sub-second
decoy win calls `group.cancelAll()` while the poisoning legs are still asleep, so
**zero `api.madfrog.online` ClientHellos leave the device** and the TSPU never
escalates. The 2 s hold only costs latency on the rare network where the decoy
itself fails. Code: `APIClient.poisonHoldMs` / `decoyLeadMs`, applied to the
primary task + direct-IP stagger in `dataWithFallback`.
