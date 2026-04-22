# Security Audit: Chameleon VPN Communication Chain

**Date:** 2026-04-22  
**Scope:** iOS client → Go backend → VPN nodes (sing-box + Xray)  
**Auditor:** Claude Code (Sonnet 4.6)

---

## Executive Summary

The codebase is significantly above average for a small VPN product. JWT signing is correct (HS256, `alg` pinned, `none` rejected), Apple Sign-In is properly verified, IAP uses cryptographic JWS chain verification, admin/mobile separation is functional. **The most dangerous finding is a CRITICAL lateral-compromise path: if the NL node is compromised, an attacker gains the cluster secret and full DB-write access to DE, including the ability to create admin-privileged users and overwrite Reality private keys.** Two HIGH findings (same JWT secret for admin+mobile, FreeKassa webhook has no rate limiting) complete the short list of urgent items.

---

## Findings

---

### FINDING-01 — CRITICAL: Compromised NL node can fully compromise DE

**Category:** Network topology / Federated sync  
**File:** `backend-go/internal/cluster/sync.go`, `backend-go/internal/cluster/routes.go`

**Description:**  
The cluster sync channel (`/api/cluster/push`) accepts a shared bearer secret (`cluster.secret`) and, upon receipt of a valid push request, performs an unauthenticated `UpsertUserByVPNUUID` for every record in the payload. The wire format (`SyncUser`) includes:
- `subscription_token` — grants VPN config download
- `apple_id` — can replace another user's Apple identity
- `is_active` + `subscription_expiry` — can grant permanent subscription to any vpn_uuid
- `device_id` — can steal device association

Critically, `SyncServer` includes:
- `reality_private_key` — the VLESS Reality X25519 private key
- `provider_login` / `provider_password` — VPS hosting credentials

A node that knows the cluster secret can push arbitrary servers with any private key, effectively becoming the authoritative source for client configs. Clients that next call `/config` will receive a config signed with the attacker's key, enabling full MITM of the VPN tunnel.

Additionally, the `handlePull` endpoint returns **all users changed since epoch** (if `since` is omitted), including subscription tokens, activation codes, apple_ids, device_ids — the complete user table.

**Attacker model:** Compromised NL node (physical or logical access to its container).

**Impact:**
1. Pull all user PII from DE (full table dump)
2. Push forged server with attacker-controlled Reality keys → MITM all VPN sessions
3. Grant unlimited subscriptions to arbitrary users
4. Overwrite provider credentials for all VPN servers

**Fix:**
1. **Remove `reality_private_key`, `provider_login`, `provider_password` from `SyncServer` wire format** (`backend-go/internal/cluster/models.go:dbServersToSyncServers`). Private keys must never leave the node they belong to; nodes independently hold their own key. Public keys are the only thing that needs to propagate.
2. Add a **per-field HMAC or signature** on SyncUser/SyncServer payloads, or better, use mTLS between peers so a compromised peer cannot masquerade.
3. Push requests should be **IP-allowlisted** to known peer IPs at the firewall level (this is noted as architecture requirement, not implemented in code).
4. Scope the `since=epoch` full-dump: return only VPN-relevant fields (uuid, username, short_id, is_active, subscription_expiry) on pull, not full user PII.

---

### FINDING-02 — HIGH: Mobile JWT and admin JWT share the same secret

**Category:** Broken Access Control  
**File:** `backend-go/internal/api/server.go:122-203`, `backend-go/internal/auth/jwt.go`

**Description:**  
Both mobile users and admin users are signed with the single `cfg.Auth.JWTSecret`. Mobile tokens carry `role: "user"` and admin tokens carry `role: "admin"/"operator"/"viewer"`. Role separation depends entirely on the `role` claim inside the JWT.

The `CookieOrBearerAuth` middleware (admin gateway) checks:
```go
if claimsResult.Role != "admin" && claimsResult.Role != "operator" && claimsResult.Role != "viewer" {
    return echo.NewHTTPError(403, "forbidden")
}
```

This check correctly prevents a mobile JWT from accessing admin routes today. However:
1. A **forged JWT** (only possible if the shared secret leaks) grants both admin and mobile access simultaneously — one secret compromise = everything.
2. The `createUser` path issues tokens with `role: "user"`. If a bug in the role assignment path ever issued `"admin"` by mistake (e.g. developer test, migration script), mobile users would get admin access.
3. There is no cryptographic separation: the same HS256 key verifies both contexts.

**Attacker model:** Any attacker who obtains the JWT secret (misconfigured logging, config file exposure, DB leak of config table).

**Impact:** Full admin API access with a forged mobile token.

**Fix:**  
Use separate JWT secrets for admin and mobile, or use asymmetric signing (RS256/ES256) with separate keypairs. Minimum fix: add a second `admin_jwt_secret` field in `AuthConfig` and wire `JWTManager` in admin routes to use it.

```go
// config.go
AdminJWTSecret string `yaml:"admin_jwt_secret"` // separate from mobile jwt_secret
```

---

### FINDING-03 — HIGH: FreeKassa webhook has no rate limit

**Category:** DoS / Replay  
**File:** `backend-go/internal/api/server.go:178-179`

**Description:**  
```go
webhooks := e.Group("/api/webhooks")
webhooks.POST("/freekassa", mobileHandler.FreeKassaWebhook)
```

The `/api/webhooks/freekassa` group is created without the `mw.RateLimit()` middleware that protects all other groups. The IP allowlist (`freekassa.IPAllowed`) provides some protection — if the whitelist is populated, only FK's IPs can call the endpoint. However:

1. If the config is deployed with an **empty `ip_whitelist`** (the code explicitly says "allow everything" in that case), the endpoint is open to the world.
2. Even with a whitelist, if FreeKassa's notification servers are used as a DDoS amplifier or FreeKassa's infrastructure is compromised, there is no server-side throttle.
3. An attacker who guesses a valid `SIGN` (MD5-based, with known `secret2`) can replay old notifications without limit.

The MD5 webhook signature is also inherently weak compared to HMAC-SHA256. There is no replay window: the same signed payload can be replayed indefinitely since `charge_id` idempotency only prevents double-crediting but does not prevent log spam or DB load.

**Attacker model:** Internet attacker when `ip_whitelist` is empty; or a party with knowledge of `secret2`.

**Impact:** DB write load (CreditDays called in a tight loop), log flooding, potential timing analysis of charge IDs.

**Fix:**
```go
webhooks := e.Group("/api/webhooks")
webhooks.Use(mw.RateLimit(s.Config.RateLimit.MobilePerMinute)) // add this line
webhooks.POST("/freekassa", mobileHandler.FreeKassaWebhook)
```
Additionally, add a timestamp-based replay window: FreeKassa sends a request timestamp — reject any notification older than 5 minutes. Emit a loud startup warning if `ip_whitelist` is empty.

---

### FINDING-04 — HIGH: Subscription token has unknown entropy (legacy `/sub/:token`)

**Category:** Sensitive Data Exposure / Broken Auth  
**File:** `backend-go/internal/api/mobile/config.go:161-224`, `backend-go/internal/db/models.go:31`

**Description:**  
The `/sub/:token` endpoint delivers a full VPN config (UUID, server IPs, Reality public key) to anyone who knows the token. The `subscription_token` column in the DB is `VARCHAR(255)` but there is **no code in the Go backend that generates it** — it appears to be populated only by the legacy Rust backend or manual admin action. Its format and entropy are unknown from the current codebase.

If tokens are short, numeric, or sequential (as is common in legacy systems), they are enumerable. Since the `/sub/:token` endpoint is rate-limited at 60 req/min per IP, an attacker using multiple IPs could enumerate tokens to harvest VPN configs for all users.

Additionally, the admin UI exposes the subscription URL as `/api/mobile/sub/:token` in `toUserResponse`. This means admin staff can see (and inadvertently copy) tokens that give full VPN access.

**Attacker model:** Internet attacker enumerating tokens across multiple IPs.

**Impact:** Full VPN config (UUID + server list + Reality public key) for any user. Enables unauthorized VPN usage at that user's expense (quota, subscription days deducted via traffic).

**Fix:**
1. Ensure subscription tokens are generated as `crypto/rand` 32-byte hex strings (256 bits entropy). Add a migration to regenerate any short tokens.
2. If the legacy endpoint is not needed for current users, deprecate and remove it.
3. Add a `X-Forwarded-For` cluster-level rate limit (not just per IP) on `/sub/` to slow enumeration.
4. Consider binding token use to device UA or adding expiry.

---

### FINDING-05 — MEDIUM: Refresh token blacklist uses only first 32 chars of token

**Category:** Authentication  
**File:** `backend-go/internal/api/mobile/auth.go:315`

```go
key := fmt.Sprintf("mrt:used:%s", req.RefreshToken[:32])
```

**Description:**  
The single-use enforcement key in Redis is keyed on only the first 32 characters of the refresh token. Two different refresh tokens sharing the same first 32 characters would collide: the second token could never be used even though it was legitimately issued.

More importantly, because the key is a prefix of the token rather than a hash, Redis keys contain a partial JWT (readable by anyone with Redis access). An admin with Redis access can extract token prefixes and potentially use them for timing attacks.

**Attacker model:** Colliding tokens (very low probability but nonzero); Redis admin.

**Impact:** Legitimate users get locked out if prefix collision occurs (extremely rare with HS256 tokens). Redis logs/dumps expose partial token values.

**Fix:**
```go
import "crypto/sha256"
hash := sha256.Sum256([]byte(req.RefreshToken))
key := fmt.Sprintf("mrt:used:%x", hash[:16]) // 128-bit collision resistance, no token bytes in key
```

---

### FINDING-06 — MEDIUM: SPB relay is L4 TCP proxy — it terminates and re-originates connections

**Category:** Network Topology  
**File:** Infrastructure / architecture (no code file)

**Description:**  
The SPB relay (185.218.0.43) is an nginx `stream` proxy that forwards `:443 → DE:2096` and `:2098 → NL:2096`. This is TCP stream proxying, not TLS termination — the VLESS Reality TLS handshake is end-to-end between the iOS client and the sing-box node.

**What this means for confidentiality:**  
The relay sees raw encrypted TCP bytes but **cannot decrypt them** because Reality uses X25519 key exchange; the relay does not hold the private key. A passive observer on the relay sees: source IP, destination IP, timing, and approximate flow volume. An active MITM by the relay is not possible without knowing the Reality private key.

**What happens if SPB relay is compromised:**
- Attacker learns which users are connecting and when (timing + volume metadata)
- Attacker can selectively block connections (drop specific users from service)
- Attacker cannot read VPN content or credentials
- Attacker cannot inject data into existing sessions

**Residual risk:**  
If the Reality private key ever leaks (e.g., via FINDING-01), the relay becomes a full TLS MITM point because it sits between client and server. The two vulnerabilities compound each other.

**Fix:** No code change needed. Document this in operational runbooks. Ensure Reality private keys are kept strictly per-node. If relay becomes untrusted, rotate the Reality keypair immediately.

---

### FINDING-07 — MEDIUM: `NodeStatus` endpoint exposes node metrics without auth when cluster is enabled

**Category:** Information Disclosure  
**File:** `backend-go/internal/api/server.go:215-217`, `backend-go/internal/api/admin/nodes.go:285-289`

```go
clusterGroup.GET("/node-status", adminHandler.NodeStatus)
```

`clusterGroup` has `cluster.ClusterAuth` applied, so `NodeStatus` **is** protected by the cluster secret. This is fine. However, `NodeStatus` returns:
- Online user count
- CPU/RAM/disk usage
- VPN protocol and port
- Node IP
- Uptime hours

The cluster secret is a single shared secret between all peers. If the NL node is compromised (FINDING-01), it also has the cluster secret and can pull DE's node-status without restriction.

**Fix:** Addressed by fixing FINDING-01. No additional action required if the cluster secret is properly isolated.

---

### FINDING-08 — MEDIUM: `generateVPNUsername` is deterministic — can enumerate users by device_id

**Category:** Privacy / User Enumeration  
**File:** `backend-go/internal/api/mobile/auth.go:406-410`

```go
func generateVPNUsername(deviceID string) string {
    hash := sha256.Sum256([]byte(deviceID))
    hexHash := hex.EncodeToString(hash[:])
    return "device_" + hexHash[:8]
}
```

**Description:**  
The VPN username is a deterministic 8-hex-char SHA-256 prefix of the device ID. With only 2^32 possible values, two users can collide. More practically: an attacker who knows a target's device ID (e.g., leaked from another app, Apple IDFA) can compute their VPN username without any server interaction. VPN usernames appear in the admin UI and in cluster sync payloads.

**Attacker model:** Attacker with knowledge of a target's device ID + access to the admin UI (or cluster pull endpoint).

**Impact:** Username disclosure, limited — by itself doesn't grant VPN access. UUID is the actual VPN credential and is random.

**Fix:** Use a random UUID for VPN usernames rather than a deterministic hash. Existing usernames don't need migration since they are internal identifiers.

---

### FINDING-09 — LOW: Device registration endpoint has no per-device-ID deduplication guard against burst creation

**Category:** Abuse / Resource exhaustion  
**File:** `backend-go/internal/api/mobile/auth.go:50-124`

**Description:**  
POST `/auth/register` accepts any `device_id` string. The rate limit is 60 req/min per IP. An attacker with multiple IPs can register many distinct device_ids, each receiving a 3-day trial subscription. There is no email verification, phone verification, or device attestation (e.g., App Attest / SafetyNet) required.

At 60/min/IP × N IPs, trial abuse is feasible. Each trial user consumes a VPN slot in sing-box.

**Attacker model:** Automated abuse from multiple IPs.

**Impact:** Trial subscription farming, VPN slot exhaustion.

**Fix:** Consider adding Apple's DeviceCheck or App Attest to the registration flow on iOS (available since iOS 14). Short-term: track registration count per IP per day (not just per minute) and cap it at 3-5 per IP per 24h.

---

### FINDING-10 — LOW: Admin CSRF protection is header-presence only, not token-based

**Category:** CSRF  
**File:** `backend-go/internal/api/middleware/security.go:43-55`

```go
func CSRFProtect() echo.MiddlewareFunc {
    ...
    if c.Request().Header.Get("X-Requested-With") == "" {
        return echo.NewHTTPError(http.StatusForbidden, "missing X-Requested-With header")
    }
    ...
}
```

**Description:**  
The CSRF protection checks only for the presence of `X-Requested-With`. This is a defense in depth measure (fetch/XHR from a different origin cannot set arbitrary headers by default under CORS). However, this is not a cryptographic CSRF token. If the `AllowCredentials: true` CORS policy is misconfigured to allow a malicious origin, this header check would not protect.

The current CORS config (`s.Config.Server.CORSOrigins`) limits origins, which mitigates this. The combination is adequate but not ideal.

**Attacker model:** XSS on an allowed origin, or CORS misconfiguration.

**Impact:** Admin state-changing actions (user deletion, subscription extension) CSRF if CORS is weakened.

**Fix:** Consider adding a proper CSRF token (double-submit cookie or synchronized token pattern) for high-impact admin mutations. Low urgency given current CORS restriction.

---

### FINDING-11 — LOW: Cluster `handlePush` accepts server upserts including `reality_private_key`

*(Documented as sub-finding of FINDING-01 but warrants separate tracking)*

**File:** `backend-go/internal/cluster/routes.go:153-163`

A push from a peer can upsert server records including `reality_private_key`. This means a peer can overwrite any server's private key in the DE database. On next `engine.Start()` or node restart, DE will load the attacker-provided private key from DB.

This is the code path:
```
POST /api/cluster/push → handlePush → UpsertServerByKey → DB → engine.Start uses DB key
```

**Fix:** Same as FINDING-01: remove `reality_private_key` from `SyncServer` wire format entirely. Each node is authoritative for its own key.

---

## Non-Issues (Investigated, Not Vulnerable)

| Area | Verdict |
|---|---|
| JWT algorithm confusion (`alg: none`) | **Safe.** `WithValidMethods([]string{"HS256"})` enforced in both `parseToken` and `VerifyRefreshToken`. |
| JWT issuer validation | **Safe.** `WithIssuer(issuer)` in both paths. |
| Apple Sign-In `iss` validation | **Safe.** `jwt.WithIssuer(appleIssuer)` + RS256 enforced. |
| Apple Sign-In `aud` with multiple bundle IDs | **Safe.** Server-side allowlist in `audienceAllowed`. |
| Apple IAP receipt client-trust | **Safe.** Full x5c chain verification against Apple root CA via `go-iap`. |
| IDOR on `/config` | **Safe.** Config is fetched by JWT `user_id`, not by URL parameter. |
| SQL injection in admin search | **Safe.** `ILIKE $1` with parameterized query; `pattern := "%" + search + "%"` is passed as a parameter, not interpolated. |
| Admin role escalation by mobile JWT | **Safe.** Mobile tokens have `role: "user"`; admin middleware rejects non-admin/operator/viewer roles. |
| Refresh token replay | **Safe.** Redis `SET NX` single-use enforcement. |
| Race condition on Apple renewal + expired | **Safe.** `CreditDays` uses `(source, charge_id)` unique constraint with `ON CONFLICT DO NOTHING` for idempotency. |
| FreeKassa HMAC verification | **Safe.** `hmac.Equal` constant-time comparison. Amount sanity check present. |
| VPN config SSRF/injection | **Safe.** User-controlled fields (UUID, username) go into JSON values, not URLs or shell commands. |
| Reality private key in client config | **Safe.** `clientconfig.go` uses only `PublicKey`. Private key never leaves backend. |
| Subscription token in logs | **Not seen.** Token appears in admin UI response but not in log fields. |

---

## Priority Fix List

| # | Severity | Finding | Effort |
|---|---|---|---|
| 1 | CRITICAL | Remove `reality_private_key` + `provider_*` from cluster sync wire format | 1h |
| 2 | CRITICAL | Add push-side validation: peer can only sync users, not server credentials | 2h |
| 3 | HIGH | Separate JWT secrets for admin and mobile | 2h |
| 4 | HIGH | Add rate limit middleware to FreeKassa webhook group | 5 min |
| 5 | MEDIUM | Fix refresh token blacklist to use SHA-256 hash as key | 15 min |
| 6 | MEDIUM | Verify subscription_token entropy — audit legacy generation path | 1h |

---

## Summary (≤200 words)

**Главная угроза:** Если NL-нода скомпрометирована, атакующий получает `cluster_secret` и через POST `/api/cluster/push` может перезаписать `reality_private_key` у DE-ноды, сделать дамп всех пользователей (включая Apple ID, device ID, subscription_token), и выдать себе бессрочную подписку. Это CRITICAL — один взломанный VPS компрометирует всю инфраструктуру. **Фикс:** убрать `reality_private_key`, `provider_login`, `provider_password` из `SyncServer` wire-формата — они никогда не должны покидать ноду.

**Второй приоритет (HIGH):** Mobile и admin JWT подписаны одним секретом. Утечка ключа = полный admin access. Решение — два отдельных секрета.

**Третий (HIGH):** FreeKassa webhook не имеет rate limit. Если `ip_whitelist` пустой — эндпоинт открыт для флуда. Пять строк кода.

**Хорошие новости:** JWT-алгоритм, Apple Sign-In, StoreKit 2 JWS chain verification, IDOR на `/config`, SQL injection в поиске — всё защищено корректно. Архитектура admin/mobile разделения работает. SPB relay не может читать VPN-трафик (VLESS Reality end-to-end).