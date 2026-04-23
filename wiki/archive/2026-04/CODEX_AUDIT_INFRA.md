# CODEX Prompt — Audit Chameleon VPN infrastructure

**Copy the whole block below into CODEX as a single prompt.**

---

## Context

You are auditing the **production infrastructure** for MadFrog VPN. Two servers, one Go backend, one domain in use. You have read access to the repo. You do **not** have SSH access from the CODEX runtime — analysis is static (code, config, git log) plus you may ask the operator (the user running CODEX) to run specific checks on the server and paste the output.

Repo layout:
```
backend-go/                 # Go backend (Chameleon)
├── cmd/chameleon/          # main.go, entrypoint
├── internal/
│   ├── api/                # HTTP handlers (mobile + admin)
│   ├── auth/               # JWT, Apple sign-in verify
│   ├── db/                 # PostgreSQL queries
│   ├── vpn/                # sing-box engine wrapper, config generator
│   ├── payments/           # Apple IAP verify + FreeKassa webhook
│   ├── monitoring/         # traffic collector
│   └── cluster/            # Redis pub/sub peer sync
├── migrations/             # SQL migrations (numbered)
├── config.yaml             # dev config (secrets via ${ENV_VAR})
├── config.production.yaml  # prod template
├── docker-compose.yml
├── nginx.conf
└── deploy.sh

admin/                      # React SPA for /admin/app/
```

Infra topology:
- **DE** `162.19.242.30` — OVH Frankfurt, primary. Runs: `chameleon` (Go), `chameleon-nginx`, `singbox` (sing-box v1.13.6-userapi fork), `chameleon-postgres`, `chameleon-redis`. Ubuntu. Access: `ssh ubuntu@162.19.242.30` (password in `~/.secrets.env:SPRINTBOX_VPS_PASSWORD` is a **different** server — don't use here; DE uses ssh keys).
- **NL** `147.45.252.234` — Timeweb. Same stack, host networking. Access: `ssh root@147.45.252.234`.
- Domains (Cloudflare):
  - `madfrog.online` → DE (apex, proxied, SSL=flexible) — public product domain.
  - `www.madfrog.online`, `mdfrog.site`, `razblokirator.ru` → DE (duplicates / reserved).
  - Legacy subdomains (`bot.`, `crew.`, `speedtest.`) still point to `85.239.49.28` (old RazblokiratorBot stack, deprecated).
- Secrets: `~/.secrets.env` (outside repo). Relevant keys: `CLOUDFLARE_API_KEY`, `ASC_*` (App Store Connect), `FREEKASSA_API_KEY`, `TIMEWEB_API_KEY`, `SPRINTBOX_VPS_PASSWORD`.

VPN protocol: VLESS Reality TCP (sing-box serves), port 2096 on DE and NL.

## Goal

Produce an **actionable security + reliability audit** of the backend and infrastructure. Treat this as a pre-launch review of a VPN service that will process paying customers.

## Scope — what to audit

### 1. Go backend code (high priority)

Audit `backend-go/internal/`:
- **`auth/`**: JWT generation, signing, validation (`jwt.go`, `middleware.go`). Apple Sign-In verifier (`apple.go`) — fresh change: audience check now accepts a list of bundle IDs; verify the list is enforced correctly and no empty-string sneaks through as a wildcard.
- **`api/server.go`, `api/mobile/`**: request validation, input sanitization, rate limits, CORS, security headers. Every handler's authN/authZ boundary.
- **`api/admin/`**: admin panel endpoints — are they behind admin JWT? CSRF? Is there a path where a mobile user can hit admin routes?
- **`db/`**: SQL injection vectors — but we're using pgx with parameterized queries, so focus on query logic: N+1 reads, missing WHERE clauses on DELETEs, timing attacks (email enumeration on login).
- **`vpn/clientconfig.go`**: the sing-box config is generated per user and returned over HTTPS. Inspect for: UUID leakage in logs, missing per-user isolation, route rules that could exfiltrate DNS to a non-tunnel resolver, fake-IP settings.
- **`vpn/singbox.go`, `vpn/engine.go`**: how does the backend control the live sing-box? Any command injection if server config comes from DB?
- **`payments/apple/verify.go`**: StoreKit 2 JWS signature check (x5c chain). Replay protection. `BundleID` mismatch handling.
- **`payments/freekassa/signature.go`**: HMAC construction, timing-safe compare, replay window.
- **`cluster/`**: Redis pub/sub trust model. A compromised node pushes a malicious user record — what happens?

### 2. Configuration

- `config.yaml` / `config.production.yaml`: are all secrets referenced as `${ENV_VAR}`? Any literal credentials?
- `docker-compose.yml`: container privileges, exposed ports, volume mounts, healthcheck logic.
- `Dockerfile` / `Dockerfile.prebuilt`: base image pinning, non-root user, multi-stage builds, trimmed image size.
- `nginx.conf`: TLS config (ciphers, protocols), proxy headers (`X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`), rate limits, `client_max_body_size`, request timeouts, access logging of paid endpoints.
- Cloudflare SSL mode is `flexible` (CF→origin is plaintext). Is this intentional? What's the plan for `full strict`?
- Nginx listens on port 80 only (no HTTPS on origin). OK under CF, but what happens if someone hits `https://162.19.242.30` directly? Is it blocked?

### 3. Secret & access hygiene

- `~/.secrets.env`: any obvious issues (unused keys, wrong scopes)?
- How are secrets delivered to production? Docker env files, compose env, ssh-copy? Where do they live on the VPS?
- SSH key configuration: do DE and NL have the same key? Is it rotated? Is root SSH disabled on DE?
- Deploy script `backend-go/deploy.sh`: does it leak secrets in logs? Does it leave world-readable files on target?
- ASC API key file `~/private_keys/AuthKey_*.p8` — permissions, backup.

### 4. Data at rest

- `chameleon-postgres` — encryption? Backups? Off-site? Retention? The `users` table with `apple_id` and traffic history is PII.
- Redis — what's stored? TTLs? Persistence?
- sing-box config file on disk — contains Reality private key. Permissions.
- Log retention: `docker logs chameleon`, nginx access log. Contain IPs, emails, tokens?

### 5. DNS / domain hygiene

- `madfrog.online`: CF proxied, SSL=flexible. Recommend `full strict` with origin cert.
- `mdfrog.site`: same origin, unclear role.
- `razblokirator.ru`: legacy, still resolves to DE. Risk: old marketing links. Plan to sunset or redirect?
- `bot.madfrog.online`, `crew.`, `speedtest.` → `85.239.49.28`. If that server is decommissioned, what breaks for users?
- Email: `@madfrog.online` MX points to `mx.cloudflare.net` — is mail actually handled, or are these vestigial?

### 6. Network & VPN operational security

- sing-box server config on DE / NL — is the config file world-readable? In Docker volume or bind-mounted?
- Reality handshake keys in DB — how rotated? What if one is compromised?
- Per-user UUID leakage via logs / metrics / admin panel.
- Outbound from VPN tunnel — is egress blocked to private ranges (no RFC1918 pivot into the DC network)?
- Rate limiting on auth endpoints (`/api/mobile/auth/apple`, `/auth/refresh`) to prevent credential stuffing.

### 7. Supply chain

- `go.sum` integrity — any replaced modules pointing to forks? `github.com/sagernet/gomobile` fork — vetted?
- Vendored Libbox.xcframework (client side) is out of scope for this audit, but the *server-side* sing-box fork (`sing-box-fork:v1.13.6-userapi`) — provenance, upstream diff, any custom patches.
- Go module vulnerabilities: run `govulncheck ./...` and report findings.

### 8. Observability & incident response

- Where does `chameleon` send logs? Structured JSON — great — but is there off-host aggregation?
- Metrics: is there a Prometheus endpoint? Alerts?
- Health check: `/health` is public — what does it leak? (We saw `{"db":"ok","redis":"ok"}` — arguably that's fine, but not universally.)
- Runbook: is there any `wiki/TROUBLESHOOTING.md` equivalent for the server side? If not, note it as a gap.

### 9. Abuse / compliance
- Terms / Privacy pages (`backend-go/landing/privacy.html`, `terms.html`): check content against actual app behaviour. Do they honestly describe data collection?
- GDPR: right-to-delete flow (`/api/mobile/user` DELETE) — does the server actually delete PII and not just soft-delete?
- Russian 152-FZ (data localization) — we're serving RU users; what's the position?
- No-logs claim: the app's landing page says "не храним логи". Verify against `docker logs chameleon` and `traffic_history` table.

### 10. Bootstrapping / runbook check

- Can a new engineer bring up a clean dev environment from `README.md` / `wiki/wiki.md` without guessing? If not, note the gap.
- Migration ordering: is the numbered migrations approach safe from gaps / duplicate sequencing?

## Methodology

1. **Static analysis** across `backend-go/`:
   - `grep -rn "fmt.Sprintf.*SELECT\|exec.Command\|os.Setenv"` for command injection / dynamic SQL.
   - Trace every `c.Bind`, `c.QueryParam`, `c.Param` to validate all inputs.
   - Check every `http.ResponseWriter` / echo `c.JSON` for leaks of internal error messages.
2. **Config review**: YAML diff against Go `Config` struct — any silent field loss? Any required field without a default?
3. **Git history**: `git log --all --source -p -- 'backend-go/internal/**.go'` looking for accidentally committed secrets / test tokens.
4. **Runtime checks** (ask the operator to run and paste output):
   - `docker compose ps`, `docker logs chameleon --tail 200`, `docker logs chameleon-nginx --tail 200`
   - `sudo ss -tlnp` on DE and NL (open ports)
   - `sudo ufw status` / `iptables -L -n` (firewall)
   - `openssl s_client -connect madfrog.online:443 -servername madfrog.online </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject -dates` (cert info)
   - `curl -sI https://madfrog.online/api/mobile/auth/apple -X OPTIONS` (CORS headers)
   - `dig +short madfrog.online @8.8.8.8` vs `@1.1.1.1` (DNS consistency)
   - `govulncheck ./...` on backend-go
5. **Threat modelling**: enumerate the top 5 attack paths (malicious user, malicious backend peer, malicious admin, network adversary, supply-chain) and explain which controls mitigate them.

## Output format

Group findings by domain (backend code, config, secrets, data, DNS, network, supply chain, observability, compliance, runbook). Within each domain, use:

```
### [SEVERITY] Short title
**Where:** file/path or server/component
**Issue:** concrete, 1-3 sentences.
**Impact:** what an attacker/operator gets if unfixed.
**Fix:** concrete remediation. Diff if small; step list if larger.
**Verification:** command or test that proves it's fixed.
```

Severities: `CRITICAL` (data loss, RCE, PII leak at scale, plaintext secret in repo), `HIGH` (auth bypass, abuse vector, legal exposure), `MEDIUM` (hardening, misconfig), `LOW` (hygiene, docs).

At the end include:

- **Top 5 must-fix** before go-public / paid users.
- **Top 3 next 30 days** — hardening that's good but not blocking.
- **Runbook gaps** — what the current team couldn't recover from without prior knowledge.

Be concrete. A vague "use strong passwords" is useless; a grep-able line or a Dockerfile diff is useful. Prefer one real finding backed by a file:line citation over ten speculative ones.
