# Chameleon Audit Report (2026-04-11)

## Scope
- `apple` (iOS app + PacketTunnel)
- `backend-go` (API + auth + cluster)
- `admin` (React/Vite panel)

## Critical

1. **TLS verification bypass in iOS fallback client (MITM risk)**
- File: `apple/ChameleonVPN/Models/APIClient.swift:38`
- File: `apple/ChameleonVPN/Models/APIClient.swift:62`
- Problem: fallback session accepts any certificate (`serverTrust`) for relay/direct-IP paths.

2. **Unauthenticated mobile config endpoint by `username`**
- File: `backend-go/internal/api/mobile/routes.go:42`
- File: `backend-go/internal/api/mobile/config.go:22`
- Problem: `/api/v1/mobile/config` is accessible without JWT and identifies user by query param.

## High

3. **Subscription expiry check missing in main config endpoint**
- File: `backend-go/internal/api/mobile/config.go:40`
- File: `backend-go/internal/api/mobile/config.go:99`
- Problem: `GetConfig` checks `is_active`, but does not block expired subscriptions (legacy endpoint does).

4. **Subscription verification trusts client transaction data**
- File: `backend-go/internal/api/mobile/subscription.go:38`
- File: `backend-go/internal/api/mobile/subscription.go:86`
- Problem: Apple Server API v2 verification is TODO; server currently trusts client `transaction_id`.

5. **Black screen on launch without Wi-Fi / unstable network**
- File: `apple/ChameleonVPN/ChameleonApp.swift:14`
- File: `apple/ChameleonVPN/Models/AppState.swift:62`
- File: `apple/ChameleonVPN/Models/AppState.swift:187`
- File: `apple/ChameleonVPN/Models/APIClient.swift:173`
- Problem: app keeps black placeholder until `initialize()` finishes; initialization awaits network config update and can stall for long timeout chains.

6. **VPN auto-reconnects after disabling in iPhone Settings**
- File: `apple/ChameleonVPN/Models/VPNManager.swift:44`
- File: `apple/ChameleonVPN/Models/VPNManager.swift:124`
- File: `apple/ChameleonVPN/Models/VPNManager.swift:68`
- Problem: `connect()` force-enables On Demand with `NEOnDemandRuleConnect`; if user disables VPN in Settings, iOS may re-enable tunnel.

## Medium

7. **Potential goroutine leak in rate limiter cleanup**
- File: `backend-go/internal/api/middleware/ratelimit.go:33`
- File: `backend-go/internal/api/middleware/ratelimit.go:75`
- Problem: background cleanup ticker has no shutdown path.

8. **`Stop()` methods are not idempotent (possible panic on double close)**
- File: `backend-go/internal/cluster/sync.go:130`
- File: `backend-go/internal/cluster/pubsub.go:147`
- Problem: direct `close(stopCh)` without `sync.Once` guard.

9. **AppState observer lifecycle risk (possible duplicate observer over app lifetime)**
- File: `apple/ChameleonVPN/Models/AppState.swift:375`
- Problem: status observer is added but no explicit remove/deinit path in `AppState`.

## Low

10. **Admin lint pipeline broken (ESLint v9 config missing)**
- File: `admin/package.json:8`
- Problem: `npm run lint` fails because `eslint.config.(js|mjs|cjs)` is missing.

11. **iOS build warning: extension/app build version mismatch**
- File: `apple/ChameleonVPN/Info.plist:14`
- File: `apple/PacketTunnel/Info.plist:17`
- Problem: app uses `$(CURRENT_PROJECT_VERSION)`, extension hardcodes `13`.

12. **Known npm security advisories in admin deps**
- File: `admin/package.json`
- Problem: `npm audit` reports 3 vulnerabilities (2 moderate, 1 high), including `vite` advisory range covering current version.

## Verification Snapshot
- `backend-go`: `go test ./...`, `go test -race ./...`, `go vet ./...`, `go build ./...` passed.
- `admin`: `npm run build` passed; `npm run lint` failed (config issue above).
- `apple`: `xcodebuild ... build` succeeded with warning about `CFBundleVersion` mismatch.
