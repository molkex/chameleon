# Internal audit & project state — 2026-05-30

Auditor: Claude (Opus orchestrator + 3 Sonnet sub-agents: backend / apple / docs+infra).
Mode: read-only review of code + docs + live NL state. Findings verified before logging.

## Verdict — are we going the right way?

**Yes, direction is sound; execution debt is the risk.** The architecture (Go backend + native Apple clients + sing-box VLESS-Reality, single-NL with a GRA failover exit) is coherent and the core money/auth paths are well-built (JWT, FreeKassa HMAC+idempotency, Apple JWS, payment double-credit guard — all verified solid). What threatens us is **operational fragility, not design**: one unreplicated NL box runs everything, a few real security gaps, and docs that have rotted to ~2300 lines of dead DE-era weight. Fix the P0s and tidy the docs and we keep moving forward cleanly.

## State snapshot (2026-05-30)

- **Live iOS:** 1.0.27 build 90 (App Store, READY_FOR_SALE). Build 91 base bumped, not yet iOS-shipped.
- **Native macOS:** build 91 shipped to **TestFlight today** (IN_BETA_TESTING) — first native build since 51 (May 11). App Store: never released (v1.0 PREPARE_FOR_SUBMISSION). Window-size fix coded (440×760), ships next Mac build.
- **VPN:** NL (147.45.252.234) sole backend + exit; GRA (54.38.243.162) 2nd 🇫🇷 exit (VPN-only, users baked).
- **Backend:** migrations 011–017 all live on NL (016 install_secret, 017 app_events verified present). Cron/backups healthy (daily + Backblaze B2).
- **Shipped today:** GRA exit, iOS picker FR/US, admin TZ, dashboard void-payment, AGENTS.md refresh, native Mac build 91, audit triage.

## Findings (prioritized, verified)

### P0 — fix first
| ID | Area | Where | Problem → Fix |
|---|---|---|---|
| SEC-01 | backend | `api/mobile/auth.go:373-383` | Apple Sign-In grants a fresh 3-day trial on **every** sign-in when sub is expired → infinite free trials per Apple ID. Cap/track trials per apple_id (issue once). |
| SEC-02 | backend | `api/server.go:56` | No `IPExtractor` → `c.RealIP()` trusts client `X-Forwarded-For` → rate-limit / FreeKassa IP-allowlist / geoIP all spoofable. Set `e.IPExtractor = ExtractIPFromXFFHeader(TrustLoopback(true), <trusted proxies>)`. |
| CFG-01b | apple/mac | `MadFrogVPNMac.entitlements` + `KeychainHelper` | macOS app lacks `com.apple.developer.keychain-access-groups` → `configStore.username` reads nil → config fetch never fires (the "stale roster on Mac" root cause). Add the entitlement (`$(AppIdentifierPrefix)com.madfrog.vpn`) + set `kSecAttrAccessGroup` on macOS. **Verify on next Mac build.** |
| CFG-01a | apple | `AppState.swift:502-514` | `silentConfigUpdate()` swallows all fetch errors, no UI signal → user silently stuck on stale config. Add staleness banner after N consecutive failures (`configStaleSince`). |
| LOG-01 | apple | `PacketTunnel/ExtensionPlatformInterface.swift:390-401` | `singbox.log` append has no size cap → hit 4 GB. Reuse `TunnelFileLogger` half-truncation, or route through it and drop the separate file. |

### P1 — soon
| ID | Area | Where | Problem → Fix |
|---|---|---|---|
| SEC-03 | backend | `vpn/clientconfig.go:197,215` | Hysteria2/TUIC emitted `Insecure:true` (no TLS verify) on prod → MITM. Provision real cert for UDP transports, set `Insecure:false`. (Matches GPT-audit transport finding.) |
| SEC-04 | backend | `api/mobile/subscription_notification.go:90-95` | Apple REFUND/REVOKE webhook is log-only → refunded users keep access until natural expiry. Implement revocation (mark refunded, recompute expiry). |
| UX-VPN | apple | `AppState.swift:1755-1771` | Foreign-VPN holds the OS tunnel → MadFrog shows silent "Disconnected". Detection (`anotherVPNActive()`/getifaddrs) exists but isn't wired to `handleStatus(.disconnected)`. Surface `L10n.Error.anotherVPNActive`. (User-reported.) |
| INF-01 | infra | NL-RED-01 (roadmap) | Backend/DB single-NL SPoF: all auth/config/payments hit NL only. No replica/standby; recovery = provision+restore (hours). Stand up Hetzner Helsinki standby. |
| INF-02 | infra | GRA `user_sync: baked-only` | New users after GRA bake aren't in GRA User API (:15380) → silent Reality reject on failover. Auto-sync new users to GRA. |
| MED-012 | backend | `api/mobile/auth.go:120-130` | install_secret Phase-1 accept-without-secret still on; no adoption tracking to flip to strict. Add build-coverage metric. |

### P2 — cleanup / debt
- **Backend:** `db/users.go:538-540` SQL interval via `fmt.Sprintf` (fragile, not injectable) → parameterize; `auth.go:599-606` `generateShortID` dead code; IAP `amountMinor=0/currency=""` (subscription.go:209) → populate from ASC/JWS; `017_app_events` no retention → add 90-day prune.
- **Apple:** `AppState.swift:1494-1532` `buildConfigWithSelector` dead code; `AppState.swift:124` `legRaceProbe` uninstantiated dead object; `currentNetworkTypeLabel()` always "unknown" (wire NWPathMonitor); `MadFrogVPNApp.swift:21` hardcoded "build 38d" log string → use CFBundleVersion; `SettingsView.swift:308` log read on main thread.
- **Infra:** legacy subdomains `bot/crew/speedtest.madfrog.online` → retired `85.239.49.28` (subdomain-takeover vector) — scrub/repoint; TLS cert renewal undocumented (no `letsencrypt-renew.md`, certbot not in cron list — verify); B2 bucket name unverified in `runtime.yaml`; SPB relay hosting unknown / MSK relay config not in repo; Sentry DSN injection undocumented.

### Verified healthy — do NOT touch
JWT access/refresh + SHA-256 single-use blacklist · FreeKassa IP-allowlist+HMAC+idempotency · Apple IAP full-chain JWS verify · `payments.CreditDays` atomic double-credit guard · `TunnelFileLogger` half-truncation · `buildOnDemandRules` (.cellular correctly guarded) · `toggleVPN` single-flight cancel-then-replace · Haptics `canImport(UIKit)` no-op.

## Docs architecture — target & migration

Current `docs/` three-tier idea (state YAML / playbook+ADR+incident MD) is good; the rot is in legacy + gaps. **Rule:** YAML = current parseable facts (what is X now); MD = why/how/what-happened/shape. One source of truth; YAML links to MD narrative, MD never duplicates YAML.

**Target tree** (evolve, don't rewrite):
```
docs/
  README.md            nav + format rules
  roadmap.yaml         now/next/later/done (+ fix stats)
  state/               YAML only — servers, domains, runtime, app-store, +payment-providers.yaml (NEW)
  arch/                MD — overview(strip live state), mesh, target, +payments.md (NEW)
  decisions/           append-only ADR (0001-0008)
  incidents/           append-only post-mortem (7 files)
  playbooks/           how-to — +letsencrypt-renew.md, +spb-relay-audit.md, +debug-vpn-ios.md (NEW)
  release-notes/  audits/  archive/   (keep)
```
**Retire:** `OPERATIONS.md` (1555 lines, 95% dead DE) → extract Deploy/Cron/Diagnostics to playbook stubs, delete rest. `PAYMENTS.md` → `state/payment-providers.yaml` + `arch/payments.md`, delete. `TROUBLESHOOTING.md` → strip resolved/DE entries, move debug patterns to `playbooks/debug-vpn-ios.md`, delete. `PLAN-auto-renewing-migration.md` → `archive/` (decision lives in ADR 0005). `infrastructure/topology.yaml` → fold remaining truth into `state/servers.yaml`, retire (DE-era dual-source).
**Quick fixes (low-risk, do anytime):** remove dangling `🤖 Mirror:` headers (point to deleted files); `roadmap#stats` incidents 2→7; add Prometheus/Grafana/node-exporter to `runtime.yaml` + `grafana.madfrog.online` to `domains.yaml`; refresh `app-store.yaml` IAP states.

## Recommended next-session plan
1. **Security batch (backend):** SEC-01, SEC-02, SEC-04 + deploy NL. (SEC-03 needs a cert — scope separately.)
2. **Mac client batch → build 92:** CFG-01b (keychain entitlement, verify config fetches + France) + UX-VPN (foreign-VPN banner) + LOG-01 + window-fix (already coded) + dead-code purge.
3. **Docs migration:** execute the retire/move plan above (mechanical, low-risk).
4. **GRA user-sync (INF-02)** + start NL-RED-01 (INF-01).
