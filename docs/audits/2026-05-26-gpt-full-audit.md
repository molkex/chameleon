# Chameleon VPN Full Audit

Date: 2026-05-26  
Auditor: GPT  
Mode: multi-agent audit, read-only on servers, no deploys/restarts/destructive commands  
Scope: Go backend, VPN/sing-box config generation, Apple clients, Admin SPA, DE Main `162.19.242.30`, NL `147.45.252.234`

## Executive Summary

The highest-risk issue is secret exposure: production Reality private keys are committed in test fixtures. Treat the affected Reality keys as compromised, rotate keys on all affected nodes, replace fixtures with non-production keys, and clean repository history.

Operationally, NL is running and healthy at the container level, but maintenance cron jobs are broken, DB backups appear stale, and cluster sync from NL to DE is failing. DE public Cloudflare-backed health works, but direct SSH audit could not complete because SSH times out during banner exchange after TCP connect.

Apple/API security has two high-risk transport findings: refresh tokens can currently go through unauthenticated HTTP fallback, and direct-IP TLS fallback disables certificate validation while carrying authenticated requests. These should be fixed before relying on fallback transport for sensitive endpoints.

## Critical Findings

### AUDIT-CRIT-001: Production Reality Private Keys Are Committed

Location:
- `backend/internal/vpn/reality_keys_test.go:8`
- `backend/internal/vpn/reality_keys_test.go:20`
- `backend/internal/vpn/clientconfig_test.go:17`
- `docs/TROUBLESHOOTING.md:235`

Evidence:
- `reality_keys_test.go` explicitly says the keypairs are from production servers.
- The test file contains private Reality keys and matching public keys.
- `clientconfig_test.go` reuses at least one production private key in fixture config.
- Troubleshooting docs also contain production Reality key material or identifying fragments.

Impact:
- Anyone with repository access or git history can impersonate affected Reality endpoints.
- Current node keys should be considered compromised.

Recommended fix:
- Immediately generate new Reality keypairs for affected nodes.
- Update DB/config for DE, NL, and any relay rows that used exposed keys.
- Replace tests with synthetic non-production keypairs generated only for fixtures.
- Remove secrets from docs, purge git history where feasible, and enable secret scanning.

## High Findings

### AUDIT-HIGH-001: Refresh Tokens Can Use Cleartext HTTP Fallback

Location:
- `clients/apple/MadFrogVPN/Models/APIClient.swift:617`
- `clients/apple/MadFrogVPN/Models/APIClient.swift:627`
- `clients/apple/MadFrogVPN/Models/APIClient.swift:279`

Evidence:
- `refreshAccessToken()` sends `refresh_token` in JSON body through `dataWithFallback`.
- `dataWithFallback` enables HTTP `:80` fallback whenever there is no `Authorization` header.

Impact:
- A refresh token can be exposed on hostile networks or compromised routes.

Recommended fix:
- Add an explicit `allowPlainHTTPFallback: false` / `sensitiveRequest: true` path.
- Never allow refresh tokens, magic tokens, signed JWS, emails, or Bearer tokens over HTTP fallback.

### AUDIT-HIGH-002: Direct-IP TLS Fallback Disables Certificate Validation

Location:
- `clients/apple/Shared/Networking/DirectConnection.swift:100`
- `clients/apple/Shared/Networking/DirectConnection.swift:104`
- `clients/apple/MadFrogVPN/Models/APIClient.swift:244`

Evidence:
- The TLS verify block calls `complete(true)`.
- Authenticated direct-IP fallback legs can carry Bearer headers and request bodies.

Impact:
- Active MITM or route hijack against direct fallback paths can read or alter API traffic.

Recommended fix:
- Pin backend certificate/public key for direct-IP TLS.
- Or restrict direct fallback to non-sensitive unauthenticated endpoints.

### AUDIT-HIGH-003: Generated sing-box Config Is Not Validated Before Write/HUP

Location:
- `backend/internal/vpn/singbox.go:457`
- `backend/internal/vpn/singbox.go:464`
- `backend/deploy.sh:270`
- `backend/tests/e2e/singbox_check_test.go:18`

Evidence:
- `writeConfigLocked()` builds JSON and atomically writes it without `sing-box check`.
- Deploy script can restart sing-box without validation.
- Existing e2e test validates a dummy minimal config, not real generated server/client configs.

Impact:
- One schema regression can reload/start sing-box with invalid config and drop VPN.
- This violates the project rule requiring `sing-box check` before testing on iPhone or deploy.

Recommended fix:
- Generate config to a temp path, run target-version `sing-box check -c <temp>`, then rename and HUP only on success.
- Extend e2e coverage to validate real generated client and server configs.

### AUDIT-HIGH-004: NL Maintenance Cron Jobs Are Broken

Location:
- Server report: `docs/AUDIT_SERVERS_2026-05-26_GPT.md`

Evidence:
- NL root crontab still points to `/opt/chameleon/backend-go/scripts/*`.
- Actual scripts are under `/opt/chameleon/backend/scripts/*`.
- Logs show repeated `not found`.
- Latest observed DB backup is from `2026-04-24`.

Impact:
- No automatic sing-box watchdog, local health check, or daily DB backup on NL.

Recommended fix:
- Update crontab paths or restore the expected script path.
- Run and verify a fresh DB backup after fixing cron.

### AUDIT-HIGH-005: NL Cannot Reach DE Cluster API

Location:
- NL runtime logs, summarized in `docs/AUDIT_SERVERS_2026-05-26_GPT.md`

Evidence:
- NL backend logs repeat `sync with peer failed` for `peer_id=de-1`, `peer_url=http://162.19.242.30:8000`.
- Error is `context deadline exceeded`.
- Direct DE HTTP/API probes timed out during audit.

Impact:
- Cluster reconciliation is not working from NL to DE.
- User/server state can drift between nodes.

Recommended fix:
- From DE console or working SSH session, inspect firewall, provider firewall, listeners, and Docker/networking.
- Decide whether cluster sync should use public `8000/tcp`; if yes, allowlist NL explicitly.

### AUDIT-HIGH-006: DE SSH Audit Could Not Complete

Location:
- DE Main `162.19.242.30`

Evidence:
- TCP connect to `22/tcp` succeeds.
- SSH times out during banner exchange before authentication.

Impact:
- Emergency access and required server-side checks on Main are degraded or unverified.

Recommended fix:
- Use OVH console or an existing trusted session to inspect `sshd`, firewall/provider firewall, `MaxStartups`, fail2ban, and load.
- Restore reliable SSH before deploy work.

### AUDIT-HIGH-007: Refresh Token Blacklist Keys Collide Globally

Location:
- `backend/internal/api/mobile/auth.go:396`
- `backend/internal/api/admin/auth.go:114`

Evidence:
- Both mobile and admin refresh handlers use the first 32 characters of the refresh token as the Redis blacklist key.
- HS256 JWTs share a stable encoded header prefix, so unrelated refresh tokens can share that prefix.
- TTL is hardcoded to 30 days rather than derived from the token expiry.

Impact:
- The first successful refresh can make later unrelated refreshes fail unpredictably.
- Revocation behavior does not exactly match token lifetime.

Recommended fix:
- Use `sha256(refreshToken)` or a JWT `jti` claim as the Redis key.
- Set blacklist TTL from the refresh token `exp`.

### AUDIT-HIGH-008: Apple IAP JWS Replay and Ownership Are Not Enforced

Location:
- `backend/internal/api/mobile/subscription.go:143`
- `backend/internal/payments/apple/verify.go:149`
- `backend/internal/payments/credit.go:115`

Evidence:
- Apple verifier parses `ExpiresDate`.
- `/subscription/verify` credits plan days from `NOW()` and does not reject expired historical transactions.
- The credit path does not bind `originalTransactionId` to the authenticated user.

Impact:
- An old valid signed transaction can extend access from today if not already in the ledger.
- A stolen/shared JWS can credit the wrong account.

Recommended fix:
- Reject expired entitlements: require `tx.ExpiresDate.After(now)` for active subscription products.
- Set subscription expiry from Apple’s `expiresDate` where applicable instead of adding days from now.
- Bind purchases to `appAccountToken` or enforce first-owner mapping for `originalTransactionId`.

### AUDIT-HIGH-009: Production Deploy Template Accepts Apple Sandbox Transactions

Location:
- `backend/config.production.yaml:104`
- `backend/config.production.yaml:106`
- `backend/deploy.sh:148`

Evidence:
- `config.production.yaml` has `payments.apple.allow_sandbox: true`.
- Deploy copies that file to production `config.yaml`.

Impact:
- Sandbox StoreKit transactions can be accepted in production if the template is deployed as-is.

Recommended fix:
- Set production template to `allow_sandbox: false`.
- Use separate staging config.
- Fail startup when public production domains run with sandbox enabled.

### AUDIT-HIGH-010: Disabled Admins Can Keep Using Existing JWTs

Location:
- `backend/internal/api/admin/routes.go:156`
- `backend/internal/api/admin/auth.go:105`
- `backend/internal/db/admin.go:128`

Evidence:
- Admin middleware verifies JWT claims and role, but does not load the admin row to check `is_active`.
- Refresh path verifies refresh token claims before issuing new tokens.
- `DeleteAdmin` only sets `is_active=false`.

Impact:
- Removed admins retain access until access-token expiry and may refresh up to refresh TTL.

Recommended fix:
- On every admin auth and refresh, load admin by ID and require `is_active=true`.
- Add `token_version` or session IDs for immediate revocation, or shorten admin token TTL.

### AUDIT-HIGH-011: Public HTTP Listeners Lack Server-Level Timeouts/Header Limits

Location:
- `backend/cmd/chameleon/main.go:346`
- `backend/cmd/chameleon/main.go:351`
- `backend/cmd/metrics-agent/main.go:138`

Evidence:
- Echo starts through `e.Start(...)`.
- Metrics agent uses `http.ListenAndServe(...)`.
- No explicit `ReadHeaderTimeout`, `ReadTimeout`, `WriteTimeout`, `IdleTimeout`, or `MaxHeaderBytes` are configured at `http.Server` level.
- Direct `8000/tcp` was reachable during runtime checks.

Impact:
- Slowloris/header DoS risk, especially while backend ports remain reachable outside nginx/Cloudflare.

Recommended fix:
- Start Echo and metrics-agent with explicit `http.Server` settings.
- Bind backend to loopback/private interfaces where possible and firewall public `8000/tcp`.

## Medium Findings

### AUDIT-MED-001: NL Advertises Hysteria2/TUIC Leaves That Are Not Running

Location:
- `backend/internal/api/mobile/config.go:79`
- `backend/internal/vpn/clientconfig.go:178`
- Server audit evidence from NL

Evidence:
- NL DB row advertises Hysteria2/TUIC ports.
- NL runtime config has those protocols disabled.
- No UDP `8443` listener was observed.

Impact:
- Clients may receive dead `nl-h2-*` and `nl-tuic-*` leaves and waste probes/failover cycles.

Recommended fix:
- Either enable UDP protocols on NL with cert/key and validated config, or clear those DB protocol ports.
- Add startup validation comparing advertised DB protocols with actual local inbounds.

### AUDIT-MED-002: User API Success Can Leave Persisted Config Stale

Location:
- `backend/internal/vpn/singbox.go:274`
- `backend/internal/vpn/singbox.go:281`

Evidence:
- After User API add/remove/replace succeeds, `writeConfigLocked()` failure is logged but the method still returns success.

Impact:
- Runtime users work until sing-box restarts; after restart they can disappear from persisted config.

Recommended fix:
- Treat persistence failure as an error or enqueue retry with alerting.

### AUDIT-MED-003: Cluster Sync Transmits Provider Credentials

Location:
- `backend/internal/cluster/models.go:60`
- `backend/internal/cluster/models.go:64`
- `backend/internal/cluster/models.go:186`
- `backend/internal/cluster/models.go:187`

Evidence:
- `SyncServer` includes `provider_login` and `provider_password`.
- Docs in `docs/ARCHITECTURE_MESH.md` already call out removing these from sync wire format.

Impact:
- Compromising one cluster peer can expose provider credentials for other peers, especially if a shared KEK is present.

Recommended fix:
- Remove provider credentials from cluster wire sync.
- Keep provider credentials node-local or behind a dedicated secret store.

### AUDIT-MED-004: Admin Settings Page Calls Missing Backend Routes

Location:
- `clients/admin/src/pages/settings.tsx:37`
- `clients/admin/src/pages/settings.tsx:47`
- `backend/internal/api/admin/routes.go:60`

Evidence:
- SPA calls `/admin/settings/branding`.
- Admin route registration has no settings routes.

Impact:
- Settings page fails and can mislead operators into thinking config changes are saved.

Recommended fix:
- Add backend routes or remove/disable the page until implemented.

### AUDIT-MED-005: Admin API Client Breaks on Valid Empty Responses

Location:
- `clients/admin/src/lib/api.ts:24`
- `backend/internal/api/admin/nodes.go:867`

Evidence:
- Admin API client always calls `res.json()`.
- Server delete route returns `204 No Content`.

Impact:
- A delete can succeed server-side while the UI shows failure and skips success handling.

Recommended fix:
- Return `undefined` for `204` or empty response bodies before parsing JSON.

### AUDIT-MED-006: Provider Message IPC Has No Timeout

Location:
- `clients/apple/MadFrogVPN/Models/VPNManager.swift:195`

Evidence:
- `sendProviderMessage` continuation waits indefinitely if the extension never calls back.

Impact:
- UI tasks using this path can hang.

Recommended fix:
- Wrap provider-message calls in a bounded timeout and map timeout to a user-visible/nonfatal error.

### AUDIT-MED-007: NetworkExtension `reasserting` Is Mutated Off Main Thread

Location:
- `clients/apple/PacketTunnel/ExtensionPlatformInterface.swift:172`
- `clients/apple/PacketTunnel/ExtensionPlatformInterface.swift:285`

Evidence:
- `clearDNSCache()` directly toggles `tunnel.reasserting`.
- Caller is `NWPathMonitor` background queue; nearby code comments say main-thread mutation is required.

Impact:
- NetworkExtension lifecycle state can race during network switches.

Recommended fix:
- Move `clearDNSCache()` mutation to the main queue or main actor.

### AUDIT-MED-008: Failed sing-box Start Can Leave CommandServer Resources Open

Location:
- `clients/apple/PacketTunnel/ExtensionProvider.swift:377`
- `clients/apple/PacketTunnel/ExtensionProvider.swift:405`
- `clients/apple/PacketTunnel/ExtensionProvider.swift:195`

Evidence:
- CommandServer starts before `startOrReloadService`.
- The outer catch sets gRPC state false and returns error, but does not call `stopSingBox()`.

Impact:
- Failed starts can leave stale sockets/resources until extension teardown.

Recommended fix:
- Close CommandServer/service explicitly on start failure.

### AUDIT-MED-009: NL SSH Allows Root Login and Password Authentication

Location:
- NL `147.45.252.234`

Evidence:
- Server audit found `permitrootlogin yes` and `passwordauthentication yes`.
- Logs show repeated brute-force attempts.

Impact:
- Increased SSH brute-force surface and higher blast radius.

Recommended fix:
- Confirm key-only access, then disable password authentication and direct root login.
- Add or verify fail2ban/source allowlisting.

### AUDIT-MED-010: Backend Container Has Docker Socket Mounted

Location:
- NL `/opt/chameleon/backend/docker-compose.yml`
- Local `backend/docker-compose.yml:44`

Evidence:
- Compose mounts `/var/run/docker.sock:/var/run/docker.sock`.

Impact:
- Backend container compromise can usually escalate to host control.

Recommended fix:
- Replace direct socket mount with a restricted Docker socket proxy or narrow sidecar for metrics/signaling.

### AUDIT-MED-011: No Global Request Body Limit

Location:
- `backend/internal/api/server.go:71`
- `backend/internal/api/mobile/payment_webhook.go:47`

Evidence:
- Middleware stack has timeout/rate-limit but no global `BodyLimit`.
- Public webhook calls `ParseForm()`.
- Many endpoints use `c.Bind(...)` without an app-level body cap.

Impact:
- Oversized bodies can consume memory/CPU; nginx may help, but the app should fail closed too.

Recommended fix:
- Add Echo `BodyLimit` globally.
- Use tighter per-route limits for auth, payment, webhook, and diagnostic endpoints.

### AUDIT-MED-012: `device_id` Acts as a Bearer Credential

Location:
- `backend/internal/api/mobile/auth.go:50`
- `backend/internal/api/mobile/auth.go:69`
- `backend/internal/api/mobile/auth.go:82`
- `backend/internal/api/mobile/auth.go:86`

Evidence:
- `/auth/register` issues tokens for any supplied `device_id`.
- Raw device IDs are logged in register flow.

Impact:
- Leaked or guessed device IDs can recover guest/device accounts.
- Logs retain a credential-like identifier.

Recommended fix:
- Replace client-supplied `device_id` auth with a server-issued per-install secret.
- Validate UUID format where applicable.
- Avoid logging raw device IDs; log a hash or short fingerprint.

### AUDIT-MED-013: Provider Credential Encryption Is Not Wired Through Config

Location:
- `backend/cmd/chameleon/main.go:101`
- `backend/cmd/chameleon/main.go:106`
- `backend/internal/config/config.go:305`
- `backend/internal/config/config.go:320`
- `backend/deploy.sh:200`

Evidence:
- App uses `cfg.Secrets.EncryptionKey`.
- Deploy writes `CHAMELEON_PROVIDERS_ENCRYPTION_KEY`.
- Config resolver currently resolves many env-backed fields, but not `Secrets.EncryptionKey`.
- Production template does not define top-level `secrets.encryption_key`.
- Nil cipher path logs that provider passwords are stored as plaintext.

Impact:
- Hosting provider credentials can remain plaintext in DB.

Recommended fix:
- Add `secrets.encryption_key: "${CHAMELEON_PROVIDERS_ENCRYPTION_KEY}"` to production config.
- Resolve it in `resolveAllEnvVars()`.
- Require it for production.

### AUDIT-MED-014: Admin Audit Table Is Unused

Location:
- `backend/migrations/init.sql:120`

Evidence:
- `admin_audit_log` exists in migrations.
- Backend code does not write destructive/admin events to it.

Impact:
- Destructive admin actions have weak forensic trail.

Recommended fix:
- Record login/logout, server CRUD, credential reveal, user delete/extend, node restart/sync with admin ID, IP, user-agent, and details.

## Low Findings

### AUDIT-LOW-001: Admin UI Shows Admin-Only Actions to Non-Admin Roles

Location:
- `clients/admin/src/pages/nodes.tsx:547`
- `backend/internal/api/admin/routes.go:85`

Evidence:
- Restart/sync buttons render unconditionally.
- Backend correctly enforces `adminOnly`.

Impact:
- Avoidable 403s and operator confusion.

Recommended fix:
- Gate destructive UI controls with `useAuth().isAdmin`.

### AUDIT-LOW-002: Docs Drift on NL Ports and Admin Path

Location:
- `docs/OPERATIONS.md`
- `backend/nginx.conf:106`

Evidence:
- Docs still mention admin under `/clients/admin/app/` in places.
- Runtime nginx serves `/admin/app/`.
- NL runtime exposes sing-box on `443/tcp`, not matching the simple `2096` table.

Impact:
- Operators validate wrong paths/ports during incidents.

Recommended fix:
- Update `docs/OPERATIONS.md` and `docs/operations.yaml` after confirming intended current topology.

### AUDIT-LOW-003: sing-box Forward-Compatibility Cleanup Needed After 1.13

Location:
- `backend/internal/vpn/clientconfig.go:542`
- `backend/internal/vpn/clientconfig.go:560`

Evidence:
- Fields such as `independent_cache` and `download_detour` are accepted for current 1.13 target, but are deprecated for later versions per sing-box docs.

Impact:
- Future 1.14+ migration needs cleanup.

Recommended fix:
- Track as a migration item and re-read official sing-box migration docs before changing target version.

## Positive Checks

- Mobile `/config` now requires JWT and identifies the user from token claims.
- Client route order is correct: `{"action":"sniff"}` first, then DNS `hijack-dns`.
- Client TUN uses `address: []`, not removed `inet4_address`.
- Client DNS FakeIP uses server `type:"fakeip"`, not legacy `dns.fakeip`.
- No `strict_route` or legacy inbound `sniff` found in generated server config on NL.
- NL `sing-box check -c /etc/singbox/singbox-config.json` returned OK per server/VPN agent.
- NL containers were running; `chameleon`, Postgres, and Redis were healthy.
- Public `https://madfrog.online/health` returned `db=ok`, `redis=ok`, `status=ok`.
- Admin production build succeeded using bundled Node and local Vite.
- Backend Go test suite passed locally.

## Verification Performed

Local:
- `go test ./...` in `backend/` passed.
- `go test -tags=e2e ./tests/e2e/...` in `backend/` passed, but current e2e only validates a dummy minimal sing-box config.
- `sing-box version` showed local `1.13.4`.
- Admin build via bundled Node: `node node_modules/.bin/vite build` passed.
- `npm run build` and `npm audit` with Homebrew Node failed due a broken local Node dynamic library dependency (`libsimdjson.29.dylib` missing). Bundled Node did not include npm CLI; Vite build was still verified directly.

Server:
- NL Docker state, listeners, nginx config test inside container, local health endpoints, public health endpoints, and sanitized recent logs were checked read-only.
- DE direct TCP ports `22`, `80`, `443`, and `2096` accepted TCP locally, but SSH banner exchange and direct HTTP responses timed out.
- Detailed server evidence is in `docs/AUDIT_SERVERS_2026-05-26_GPT.md`.

## External References

- sing-box migration docs: https://sing-box.sagernet.org/migration/
- sing-box deprecated feature list: https://sing-box.sagernet.org/deprecated/
- sing-box route rule actions: https://sing-box.sagernet.org/configuration/route/rule_action/
- sing-box legacy DNS server docs: https://sing-box.sagernet.org/configuration/dns/server/legacy/

## Recommended Fix Order

1. Rotate exposed Reality keys and remove committed production key material.
2. Restore DE SSH and direct cluster connectivity; fix NL cron/backups.
3. Fix refresh-token blacklist keying and Apple IAP replay/ownership/sandbox controls.
4. Block cleartext fallback for sensitive Apple API calls and pin/directly validate direct-IP TLS.
5. Add mandatory `sing-box check` before config persistence/HUP/deploy.
6. Add server-level HTTP timeouts/body limits and firewall direct backend ports.
7. Fix NL advertised protocol drift or enable the advertised protocols.
8. Remove provider credentials from cluster sync and wire provider encryption.
9. Fix admin settings route drift and `204` parsing.
10. Tighten NL SSH and Docker socket exposure.

## Signature

Signed: GPT  
Date: 2026-05-26
