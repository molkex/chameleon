# Claude Security Guidance — Chameleon / MadFrog VPN

Project-specific security rules. Sits alongside the upstream
[`security-guidance` plugin](https://code.claude.com/docs/en/security-guidance)
that ships with Anthropic's default patterns; this file encodes the lessons
the multi-agent audits surfaced in builds 75–88 (May 2026). Every rule here
exists because we already shipped the inverse mistake at least once.

> **For Claude:** when editing any file in this repo, check the rules below
> BEFORE writing. If your change matches a "Never" pattern, stop and propose
> the "Always" pattern instead. When you fix a security bug, add a new rule
> here so the next pass doesn't regress.

---

## iOS / Swift

### TLS + cert validation

- **Never** use `sec_protocol_options_set_verify_block` with an unconditional
  `complete(true)` callback. We did this once in `DirectConnection.swift` and
  spent ~2 weeks shipping H-002 (mark sensitive endpoints to skip direct-IP)
  and H-002b (add `SecPolicyCreateSSL(true, sni)` + `SecTrustEvaluateWithError`)
  before the fallback was safe again.
- **Always** validate the cert chain against the *expected SNI* — not the
  IP and not the URL host, the SNI we presented in the ClientHello.
- **Never** disable App Transport Security (ATS) in `Info.plist`
  (`NSAllowsArbitraryLoads`). If a single domain genuinely needs cleartext,
  whitelist it via `NSExceptionDomains` and document why.

### Sensitive endpoints + race fallback

- **Never** add a new endpoint that handles refresh tokens, magic tokens,
  signed JWS receipts, or device-bound credentials without passing
  `sensitive: true` to `APIClient.dataWithFallback`. The flag opts out of
  HTTP:80 cleartext legs (H-001) *and* direct-IP TLS legs (H-002).
- **Never** weaken the `sensitive=true → no HTTP:80` invariant in
  `APIClient.raceLegPlan` — HTTP:80 carries Bearer/refresh/JWS over
  cleartext, no fix exists short of removing the leg.
- **The direct-IP gate** is now relaxable per-endpoint as of H-002b
  (`DirectConnection` validates cert chain against SNI via
  `SecPolicyCreateSSL` + `SecTrustEvaluateWithError`). Specifically
  `refreshAccessToken` could safely allow direct-IP fallback so RU users
  on Cloudflare-blocked networks can refresh tokens. Still keep direct-IP
  blocked for `requestMagicLink` / `registerDevice` / `verifySubscription`
  until each is individually reasoned through.
- **Always** add a `APIClientSensitiveFlagTests` case for any new endpoint
  introduced with `sensitive: true`. The regression test costs ~10 lines and
  has caught two regressions already.

### NetworkExtension / VPNManager

- **Never** call `session.sendProviderMessage` without a timeout. The system
  continuation hangs forever if the extension is jetsam'd between receiving
  the message and replying. Use `VPNManager.raceWithTimeout` (5s default).
  This was MED-006.
- **Never** optimistically write `connected=true` to the App-Group widget
  snapshot in `VPNControl.perform(.start)`. The widget process can't observe
  the actual outcome — only `ExtensionProvider.publishWidgetState` can.
  Optimistic-disconnected (`.stop`) is fine; optimistic-connected lies.
  See `VPNControl.publishesOptimisticOnStart = false`.
- **Never** persist a stale `selectedServerTag` for a country that has been
  retired from the topology. `fallbackFromCountry` writes both
  `commandClient.selectOutbound` AND `configStore.selectedServerTag = next`
  so the live override and the persisted intent match after restart (P1-3).

### App Group + widget state

- **Never** swallow the `App Group container is unavailable` error in
  `AppConstants.sharedContainerURL`. Fail loud (`fatalError`) — silent
  fallback to `.documentDirectory` splits the main app and extension into
  separate sandboxes and silently desyncs config/logs.
- **Always** route widget state writes through `WidgetVPNSnapshot.write` —
  the optimistic and authoritative writers must use the same code path or
  they'll drift.

### Localization + UI errors

- **Never** show an English-only error message to the user via
  `VPNErrorMapper`. Add both `en` and `ru` strings to
  `Resources/{en,ru}.lproj/Localizable.strings` and reference via `L10n`.
  This was a build-77 polish miss.

---

## Backend / Go

### Auth + JWT

- **Never** trust `device_id` from the request body as an authentication
  bearer beyond the initial registration. `device_id` is client-asserted
  and not server-issued; anyone who guesses or scrapes a device_id can
  hijack the account. The MED-012 followup will introduce a server-issued
  `install_secret` returned on first register; until then, treat `device_id`
  as identity, not credential.
- **Always** verify refresh-token blacklist via SHA-256 of the FULL token
  (`sha256.Sum256([]byte(refreshToken))`), not a fixed-length prefix.
  HS256 JWT headers share a stable prefix, so `token[:32]` collides across
  unrelated tokens. This was H-007.
- **Always** use `auth.RequireAuth` middleware on admin routes. The router
  has a single chokepoint — adding a new admin handler without the middleware
  exposes it to unauth callers.
- **Never** put credentials in URL query strings, even for "internal" cluster
  calls. They land in nginx access logs, journald, ELK. Use `Authorization`
  headers or `X-Cluster-Secret` headers, both already supported.

### singbox engine (`internal/vpn/singbox.go`)

- **Never** log-and-ok a `writeConfigLocked()` failure after a User-API
  mutate. The in-memory and on-disk state will diverge — runtime keeps the
  user, restart loses them. Roll back the User-API change and surface the
  error (this is MED-002, fixed but easy to re-introduce when adding a new
  user mutation path).
- **Always** validate every new singbox config field against
  `sing-box check -c config.json` ON THE NODE before declaring success.
  Local validation alone has missed deprecated-option errors twice.

### Admin audit log (`admin_audit_log` table)

- **Always** call `h.recordAudit` (or `h.recordAuditForAdmin` during the
  unauth login path) on any admin handler that mutates state or reveals
  secrets. The wired handlers as of build 89 are: login (success/failed),
  logout, user.delete, user.extend_subscription, node.restart_singbox,
  server.{create,update,delete}, server.credentials.{reveal,reauth_failed},
  admin.{create,delete}. New mutating endpoints MUST add an audit call.
- **Never** include the request body (passwords, tokens, refresh_token,
  full JWT) in the `details` field of an audit row. The table is plain
  TEXT and an audit table leak becomes a credentials leak.
- **Always** pass user-supplied strings through `auditSafeUsername` (or an
  equivalent strip-nonprintable + length-cap) before they land in the
  `details` field. A user who types their password into the username
  field would otherwise leak it cleartext into `login.failed` audit rows;
  control characters in the input could let a log shipper interpret
  embedded newlines as separate log lines (log injection).

### Apple receipt verification (`internal/payments/apple/`)

- **Never** trust the `productID` or `transaction_id` from the iOS client
  body — verify the signed JWS server-side and use the verifier's
  `productId` + `originalTransactionId` from the trusted payload.
- **Always** reject JWS whose `x5c` header has fewer than 3 certs (rejects
  Xcode debug builds using local `.storekit` configs — they sign with a
  self-signed dev cert that would otherwise bypass receipt validation).
  See `assertRealAppleChain`.
- **Never** silently accept a previously-applied transaction's `chargeID`
  on a fresh credit — payments are idempotent per `chargeID`, replaying
  an expired one is H-008.

### Docker / deploy

- **Never** bind `/var/run/docker.sock` read-write into a container that
  handles untrusted input. The chameleon container does this today
  (MED-010), it should migrate to `tecnativa/docker-socket-proxy` with
  a path whitelist. Until then, no new untrusted-input handlers may be
  added to that container.
- **Always** use `--no-deps` when restarting chameleon via deploy.sh.
  Without it, `docker compose up` cascades into singbox and drops every
  live VPN connection.

### Secrets

- **Never** commit secrets to the repo. `~/.secrets.env` is the canonical
  store for the developer machine; production secrets land in
  `/opt/chameleon/.env` on each node (root-owned, 600 perms).
- **Never** echo or log a secret value, even partially. `head -c 4` of a
  high-entropy secret is enough to confirm a guess via timing.

---

## Infrastructure / ops

### Health checks + alerts

- **Always** parameterize port numbers in `backend/scripts/health-check.sh`
  via env (`VPN_PORT=${VPN_PORT:-443}`). A hardcoded port spammed Telegram
  every 5 min for ~1h on 2026-05-27 when NL's VLESS port was canonicalized
  from 2096 → 443 and the check wasn't updated.
- **Always** use `\b` word boundary in `ss -tlnp | grep -q ":${PORT}\b"`.
  Without it, `:44300` matches `:443` and silently masks an outage.

### Backups

- **Always** maintain both on-host AND off-host backups. NL's
  `db-backup.sh` runs daily `pg_dump` → `/var/backups/chameleon/` (7-day
  retention) AND pushes to Backblaze B2 bucket `madfrog-vpn-backups`
  (30-day retention, us-east-005 region for jurisdictional separation
  from NL). B2 push uses rclone with config at
  `/root/.config/rclone/rclone.conf` and the `b2-madfrog` remote; the
  application key is restricted to that bucket only (Read+Write, no list-
  all-buckets capability).
- **Always** rotate the B2 application key when an admin with key access
  leaves or annually, whichever comes first. Rotation flow: create new key
  in Backblaze UI → update `/root/.config/rclone/rclone.conf` on NL +
  `~/.secrets.env` on dev machine → verify next backup pushes → delete
  old key in UI.
- **Always** verify backup script paths in cron match reality. We've had
  two separate "broken cron path" outages where someone renamed
  `backend-go/` → `backend/` and forgot to update the crontab; for ~33
  days nothing backed up.
- **Always** include the B2 push step's failure handling: B2 failure is
  NOT fatal to db-backup.sh (local backup is the primary safety net), but
  must trigger a Telegram alert so it gets attention.

---

## App Store / ASC

### Submission flow

- **Never** publish an app version to `READY_FOR_SALE` availability without
  confirming that all referenced IAPs are in `APPROVED` state. Build 75 was
  approved on May 15 but the 4 non-renewing IAPs sat in `WAITING_FOR_REVIEW`
  because they weren't bundled with the binary submission — users would see
  a broken paywall. Always check via `ascinit audit-iap` before flipping
  availability.
- **Never** submit a build via `xcodebuild -exportArchive` without verifying
  the resulting `ipa` was signed with the Distribution profile, not the
  Development one. The `signingStyle: automatic` in `ExportOptions.plist`
  + `-allowProvisioningUpdates` does the right thing; manual override is a
  footgun.

### Resolution Center messages

- **Always** read Apple Resolution Center messages within 24h of receipt.
  Even non-blocking "informational" messages can escalate to forced removal
  if ignored. The ASC API does NOT expose message bodies — use Claude-in-
  Chrome MCP to navigate
  `/apps/<id>/distribution/reviewsubmissions/threads/<thread-id>` and
  read the page text.

---

## Plugin coverage gaps (where the upstream `security-guidance` doesn't help)

The shipped `security-guidance` plugin checks Edit/Write tool calls for
hardcoded patterns (mostly: GitHub Actions injection, `child_process.exec`,
unsafe deserializers). It does NOT cover:
- Swift / iOS-specific patterns (see iOS section above)
- Go-specific (e.g., `sql.DB.Exec` with string interpolation, JWT secret
  reuse across signing modes)
- Domain-specific business invariants (audit log requirement, sensitive flag,
  optimistic widget writes)
- Cross-file invariants (e.g., when adding an admin handler, the audit-log
  call MUST be present)

For now, Claude reads this file on session start (via CLAUDE.md reference)
and self-enforces. Long-term: turn the rules above into a project-local
hook that runs alongside the upstream plugin.

---

## Lineage / version history

- 2026-05-27 — initial file, distilling CRIT-001 + H-001..H-011 +
  MED-001..MED-014 audit findings from build 86 cycle.
- 2026-05-27 (later same day) — security-reviewer agent pass found
  `SyncConfig` missing audit call (fixed) + recommended `auditSafeUsername`
  for `login.failed` rows (added). H-002b cert validation note clarified —
  direct-IP gate now relaxable per-endpoint after cert chain validation
  landed.
- 2026-05-27 (evening) — B2 off-host backup wired into db-backup.sh
  (rclone, 30-day retention, us-east-005 region for jurisdictional
  separation). Documented rotation policy and failure-handling expectations
  for the B2 push step.
- _Add an entry every time a rule is added or revised._
