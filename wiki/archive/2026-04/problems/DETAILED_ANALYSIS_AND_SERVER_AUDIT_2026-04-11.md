# Detailed Analysis and Server Audit (2026-04-11)

## Scope
- Local code audit: `backend-go`, `apple`, `admin`
- Remote checks: `de` (`162.19.242.30`), `nl` (`194.135.38.90`)
- Public endpoint checks: `razblokirator.ru`, relay IP `185.218.0.43`

## How the audit was performed
- Static inspection of backend/iOS/admin code and deployment scripts.
- Local verification:
  - `go test ./...`
  - `go test -race ./...`
  - `go vet ./...`
  - `go build ./...`
  - `npm run build`
  - `xcodebuild ... build`
- Live infra verification via SSH (read-only) and HTTP/TLS checks from this machine.

## Confirmed Issues (Code)

1. **CRITICAL: iOS fallback TLS trust bypass (MITM risk)**
- `apple/ChameleonVPN/Models/APIClient.swift`
- Fallback session accepts any server trust (`InsecureDelegate`).

2. **CRITICAL: Mobile config endpoint without JWT**
- `backend-go/internal/api/mobile/routes.go`
- `backend-go/internal/api/mobile/config.go`
- `/api/v1/mobile/config` is callable with only `username` query parameter.

3. **HIGH: Missing subscription-expiry enforcement in main mobile config endpoint**
- `backend-go/internal/api/mobile/config.go`
- `GetConfig` checks `is_active`, but does not block expired subscriptions.

4. **HIGH: Subscription verification trusts client input**
- `backend-go/internal/api/mobile/subscription.go`
- Apple Server API v2 verification is still TODO.

5. **HIGH: Black screen on app start without stable internet**
- `apple/ChameleonVPN/ChameleonApp.swift`
- `apple/ChameleonVPN/Models/AppState.swift`
- App renders full black placeholder while `initialize()` awaits network-heavy config refresh chain.

6. **HIGH: VPN auto-reconnect after disabling in iOS Settings**
- `apple/ChameleonVPN/Models/VPNManager.swift`
- `connect()` force-enables On-Demand (`NEOnDemandRuleConnect`), so manual off in Settings can be reverted by iOS.

7. **MEDIUM: Rate limiter cleanup goroutine has no shutdown path**
- `backend-go/internal/api/middleware/ratelimit.go`

8. **MEDIUM: `Stop()` methods in cluster components are non-idempotent**
- `backend-go/internal/cluster/sync.go`
- `backend-go/internal/cluster/pubsub.go`

9. **LOW: Admin lint pipeline broken**
- `admin/package.json`
- ESLint v9 config file missing (`eslint.config.*`).

## Confirmed Issues (Servers/Production Runtime)

### A. Cron path drift breaks monitoring and backups

#### DE node (`ubuntu@162.19.242.30`)
- Crontab points to:
  - `/home/ubuntu/chameleon/backend-go/scripts/health-check.sh`
  - `/home/ubuntu/chameleon/backend-go/scripts/db-backup.sh`
- These files **do not exist**.
- Actual files exist under `/opt/chameleon/backend-go/scripts/...`.
- Result:
  - `/var/log/chameleon-health.log` missing
  - `/var/log/chameleon-backup.log` missing
  - `/var/backups/chameleon` missing

#### NL node (`root@194.135.38.90`)
- Crontab points to:
  - `/root/chameleon/backend-go/scripts/health-check.sh` (missing)
  - `/root/chameleon/backend-go/scripts/db-backup.sh` (missing)
  - `/opt/chameleon/backend-go/scripts/singbox-watchdog.sh` (exists)
- Logs confirm recurring failures:
  - `/var/log/chameleon-health.log`: repeated `...health-check.sh: not found`
  - `/var/log/chameleon-backup.log`: one successful backup on `2026-04-10`, then `...db-backup.sh: not found`

### B. Relay host configured in app is unreachable over HTTP
- Relay in app config: `185.218.0.43` (`russianRelayURL`)
- Public checks to:
  - `http://185.218.0.43/health`
  - `http://185.218.0.43/api/v1/mobile/config?...`
  - `http://185.218.0.43/connect`
- Result: consistent timeout (from local machine and from both nodes).
- This directly worsens fallback behavior for iOS.

### C. sing-box logs show repeated REALITY handshake failures
- On both nodes, `singbox` logs contain many:
  - `TLS handshake: REALITY: processed invalid connection`
- Frequent source observed: `185.218.0.43` plus other internet scanners.
- Indicates persistent malformed/probing traffic; not fatal right now, but noisy and can mask real incidents.

### D. Backend port `8000` is publicly exposed
- DE: firewall inactive (`ufw inactive`), backend listens on `*:8000`.
- NL: `ufw` explicitly allows `8000/tcp`.
- Implication: backend is reachable directly by IP (bypassing CDN layer and some perimeter controls).

### E. Cluster sync appears operational
- Both nodes:
  - `/health` locally OK (`db: ok`, `redis: ok`)
  - Peer-to-peer `/api/cluster/pull/push` traffic successful in logs.
- Public unauthenticated cluster calls return `401 missing authorization` (good).

## Product Symptoms and Root Causes

### 1) "Black screen if opened without Wi-Fi"
- Root cause: startup waits on network-dependent initialization before showing non-black UI.
- Compounded by fallback chain timeouts and currently unreachable relay.

### 2) "VPN re-enables itself after turning it off in iPhone Settings"
- Root cause: On-Demand is enabled in app profile on connect, so iOS auto-reasserts tunnel after manual off.

## Priority Fix Plan

1. Fix cron path installation in deploy flow (enforce one canonical root: `/opt/chameleon`), then reinstall crontab lines.
2. Restore relay availability or remove dead relay from fallback order immediately.
3. Remove trust-all TLS fallback in iOS client; replace with proper validation/pinning.
4. Protect `/api/v1/mobile/config` with JWT and bind to authenticated identity.
5. Adjust app startup flow: render onboarding/main shell immediately, run config refresh in background with strict timeout.
6. Redesign On-Demand policy: opt-in only, explicit UX control, and deterministic disable flow.
7. Restrict backend `:8000` exposure at firewall level to trusted peers/admin IPs only.

## Current Server Health Snapshot
- Containers on both nodes are up and healthy (`chameleon`, `nginx`, `postgres`, `redis`, `singbox`).
- No restart loops currently.
- Main API health checks pass on both nodes.
- Monitoring/backup automation is currently unreliable due cron path mismatch.
