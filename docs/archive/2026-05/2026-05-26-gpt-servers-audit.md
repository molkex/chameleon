# Chameleon VPN Server Audit

Date: 2026-05-26  
Auditor: GPT  
Scope: read-only server audit for DE Main `162.19.242.30` and NL `147.45.252.234`  
Mode: no file changes on servers, no restarts, no deploys, no destructive commands, secrets redacted

## Executive Summary

NL `147.45.252.234` is reachable and the main containers are running, but its cron-based watchdog, health check, and database backup jobs are broken because cron still points to `/opt/chameleon/backend-go/scripts/*`, while the scripts exist under `/opt/chameleon/backend/scripts/*`. Last observed DB backup in `/var/backups/chameleon` is from `2026-04-24`.

DE `162.19.242.30` answered the public Cloudflare-backed `/health` endpoint, but direct SSH audit could not be completed: TCP port 22 accepts connections, then SSH banner exchange times out. Direct HTTP/API probes to DE also timed out from local and from NL. NL logs confirm repeated cluster sync failures to DE every 5 minutes.

## Findings

### HIGH: NL cron maintenance jobs are broken

Server: NL `147.45.252.234`

Evidence summary:
- Root crontab runs:
  - `* * * * * /opt/chameleon/backend-go/scripts/singbox-watchdog.sh`
  - `* * * * * /opt/chameleon/backend-go/scripts/health-check.sh`
  - `0 3 * * * /opt/chameleon/backend-go/scripts/db-backup.sh`
- Those files are missing.
- Existing scripts are under `/opt/chameleon/backend/scripts/`.
- `/var/log/singbox-watchdog.log`, `/var/log/chameleon-health.log`, and `/var/log/chameleon-backup.log` repeatedly show `not found`.
- Latest DB backup file found in `/var/backups/chameleon` is `2026-04-24`.

Impact:
- No automatic sing-box watchdog.
- No automatic local health check.
- No daily database backups since at least `2026-04-25`.

Recommended fix:
- Update root crontab paths from `/opt/chameleon/backend-go/scripts/*` to `/opt/chameleon/backend/scripts/*`, or restore the expected `backend-go/scripts` location.
- Run one manual backup after fixing cron, verify a new file appears in `/var/backups/chameleon`, then add a backup freshness check to monitoring.

### HIGH: NL cannot reach DE cluster API directly

Servers: NL `147.45.252.234`, DE `162.19.242.30`

Evidence summary:
- NL `chameleon` logs repeat every 5 minutes:
  - `sync with peer failed`
  - `peer_id=de-1`
  - `peer_url=http://162.19.242.30:8000`
  - `context deadline exceeded`
- From NL, direct probes to DE ports `22`, `80`, `443`, `8000`, and `2096` timed out.
- From local, TCP connect to DE ports succeeds, but HTTP requests to direct DE IP on `80`, `443`, and `8000` do not return application responses within timeout.

Impact:
- Cluster reconciliation from NL to DE is not working.
- User/server state can drift between nodes.
- Failover and multi-node consistency assumptions are weaker than documented.

Recommended fix:
- On DE, inspect firewall, provider firewall, Docker port publishing, and service listeners from the host console or a working SSH session.
- Confirm DE allows NL source IP `147.45.252.234` to `8000/tcp` if cluster sync is intentionally direct.
- Consider using a private overlay or explicit allowlist rules for cluster sync rather than public IP routing.

### HIGH: DE SSH audit could not be completed

Server: DE `162.19.242.30`

Evidence summary:
- `nc` to `162.19.242.30:22` succeeds from local.
- `ssh ubuntu@162.19.242.30`, `ssh root@162.19.242.30`, and `ssh admin@162.19.242.30` all timed out during SSH banner exchange.
- Because SSH did not reach authentication, no host-level checks could be performed on DE.

Impact:
- Emergency/operator access to the main server may be degraded.
- Full DE audit items remain unverified: Docker state, nginx syntax, backups, cron, firewall, sing-box version, logs, disk/memory/load.

Recommended fix:
- Use provider console or an existing trusted session to inspect `sshd`, `journalctl -u ssh`, firewall/provider firewall, `MaxStartups`, fail2ban/deny rules, and system load.
- Restore reliable SSH before relying on DE as the main operational node.

### MEDIUM: NL SSH is exposed with root login and password authentication enabled

Server: NL `147.45.252.234`

Evidence summary:
- Effective `sshd -T` settings:
  - `permitrootlogin yes`
  - `passwordauthentication yes`
  - `maxauthtries 6`
  - `maxstartups 10:30:100`
- Recent SSH logs show repeated password attempts against `root`, `admin`, `user`, and other usernames from internet sources.

Impact:
- Increased brute-force surface.
- Root SSH plus password authentication raises blast radius if password auth is ever weak or reused.

Recommended fix:
- Disable password authentication after confirming key-only access.
- Prefer a non-root admin user with sudo.
- Add fail2ban or equivalent rate limiting if not already present.
- Consider source allowlisting for SSH where operationally possible.

### MEDIUM: NL exposes services and firewall rules beyond the documented core surface

Server: NL `147.45.252.234`

Evidence summary:
- Listening/open services include:
  - `22/tcp` SSH
  - `80/tcp` nginx
  - `443/tcp` sing-box
  - `8000/tcp` chameleon backend
  - `10050/tcp` zabbix agent
  - `51820/udp` WireGuard
  - localhost-only: `5432`, `6379`, `9090`, `15380`, `8080`, `8388`, `59347`
- UFW additionally allows `443/udp`, `8443/udp`, `8488/tcp`, and `8489/tcp`.
- Docs describe VPN on `2096`, but NL currently has sing-box listening on `443/tcp` and no observed `2096` listener in `ss` output, despite TCP connect checks succeeding from local.

Impact:
- Actual exposure differs from `docs/OPERATIONS.md`.
- Harder incident response and higher chance of stale firewall openings.

Recommended fix:
- Reconcile intended public ports with actual listeners and UFW/provider firewall.
- Remove unused public allows.
- Update `docs/OPERATIONS.md` after confirming the intended NL design.

### MEDIUM: NL application container has Docker socket mounted

Server: NL `147.45.252.234`

Evidence summary:
- `/opt/chameleon/backend/docker-compose.yml` mounts `/var/run/docker.sock:/var/run/docker.sock`.
- Compose comment says it is used for `docker ps` metrics and `docker kill -s` signaling.

Impact:
- If the backend container is compromised, Docker socket access can usually become host-level control.

Recommended fix:
- Replace direct Docker socket access with a narrow sidecar/API, rootless metrics exporter, or a restricted Docker socket proxy.
- If signaling sing-box is required, expose only the one operation needed.

### MEDIUM: NL admin app route is not available

Server: NL `147.45.252.234`

Evidence summary:
- `http://147.45.252.234/clients/admin/app/` returns nginx `404`.
- Nginx logs include `/clients/admin/app/index.html is not found`.

Impact:
- If NL is expected to serve the admin SPA, it is broken.
- If NL is not expected to serve admin, docs/routing should make that explicit.

Recommended fix:
- Decide whether NL should serve admin SPA.
- If yes, deploy the admin build to the expected nginx path.
- If no, block or redirect that path and update docs.

### LOW: NL file ownership shows preserved local UID/GID

Server: NL `147.45.252.234`

Evidence summary:
- Several `/opt/chameleon` scripts and backup files are owned by numeric/user values like `501 staff`.

Impact:
- Not immediately breaking, but it complicates ownership expectations and future automation.

Recommended fix:
- Normalize ownership for deployed files to an operational user/group, for example `root:root` for scripts and an app-specific user for writable data.

### LOW: NL has no swap

Server: NL `147.45.252.234`

Evidence summary:
- Memory: `1.9GiB`
- Swap: `0B`
- Current memory pressure is low: about `1.3GiB` available during audit.

Impact:
- Low immediate risk, but a transient memory spike can trigger OOM kills instead of degrading gradually.

Recommended fix:
- Consider a small swapfile or explicit container memory limits/OOM monitoring.

## Healthy/Expected Observations

- NL OS: Ubuntu `24.04.4 LTS`, kernel `6.8.0-117-generic`.
- NL load during audit: low (`0.09`, `0.08`, `0.08`).
- NL disk usage: root filesystem about `26%` used.
- NL failed systemd units: none.
- NL containers:
  - `chameleon`: up, healthy.
  - `chameleon-nginx`: up.
  - `singbox`: up.
  - `chameleon-postgres`: up, healthy.
  - `chameleon-redis`: up, healthy.
  - `singbox-ss-ws`: up.
- NL nginx syntax check inside container: successful.
- NL sing-box version: `1.13.6-userapi`.
- NL local health:
  - `http://127.0.0.1/health`: `200`, `db=ok`, `redis=ok`.
  - `http://127.0.0.1:8000/health`: `200`, `db=ok`, `redis=ok`.
  - `http://127.0.0.1:9090/version`: `200`, `sing-box 1.13.6-userapi`.
- Public Cloudflare-backed `https://madfrog.online/health`: `200`, `db=ok`, `redis=ok`.
- Public Cloudflare-backed `https://madfrog.online/api/v1/mobile/healthcheck`: `200`, 32 KB probe body.

## Not Verified

- DE host OS, Docker containers, images, compose status, nginx syntax, cron, timers, backups, firewall, listening sockets, local logs, and sing-box version were not verified because SSH banner exchange timed out.
- DE direct service behavior needs host-side verification because direct TCP connects and application-layer responses disagree.
- Secret values were intentionally not read or reported.

## Read-Only Commands Executed

Local/repository:
- `pwd`
- `rg --files docs | sort`
- `sed -n '1,240p' docs/OPERATIONS.md`
- `git status --short`
- `rg -n "(GET|POST|health|/health|ready|metrics|ping)" backend/internal backend/cmd backend/nginx.conf backend/docker-compose.yml | head -160`

DE SSH attempts:
- `ssh -o BatchMode=yes -o ConnectTimeout=10 ubuntu@162.19.242.30 '...'`
- `ssh -o BatchMode=yes -o ConnectTimeout=20 -o ConnectionAttempts=2 ubuntu@162.19.242.30 'hostname; uptime'`
- `ssh -o BatchMode=yes -o ConnectTimeout=15 root@162.19.242.30 'hostname; uptime'`
- `ssh -o BatchMode=yes -o ConnectTimeout=15 admin@162.19.242.30 'hostname; uptime'`

NL host checks:
- `ssh -o BatchMode=yes -o ConnectTimeout=10 root@147.45.252.234 'hostnamectl; uname -a; uptime; free -h; df -hT; ...'`
- `docker ps --format ...`
- `docker images --format ...`
- `docker compose ls`
- `ss -tulpen`
- `systemctl --failed --no-pager`
- `systemctl list-timers --all --no-pager`
- `crontab -l`
- `ls -la /etc/cron.d /etc/cron.daily /etc/cron.weekly`
- `ufw status verbose`
- `iptables -S | head -120`
- `docker compose ps` in `/opt/chameleon/backend`
- `docker compose ps` in `/opt/chameleon/backend-go`
- Redacted structural grep of `/opt/chameleon/backend/docker-compose.yml` and `/opt/chameleon/backend-go/docker-compose.yml`
- `docker exec chameleon-nginx nginx -t`
- `docker exec chameleon-nginx nginx -v`
- `docker exec singbox sing-box version`
- Local curls to `127.0.0.1` health/version endpoints
- Redacted `docker logs --tail/--since` for `chameleon`, `chameleon-nginx`, `singbox`, `chameleon-postgres`, `chameleon-redis`, `singbox-ss-ws`
- `find` listings for backup scripts and backup files
- Redacted `journalctl -u docker -u ssh -u zabbix-agent --since '24 hours ago'`
- `sshd -T | grep ...`
- `grep -Rsn '/var/run/docker.sock' ...`

Network probes:
- `nc -vz -w 5` for DE and NL ports `22`, `80`, `443`, `8000`, `2096`
- `curl -k -sS --max-time ...` for:
  - `https://madfrog.online/health`
  - `https://madfrog.online/health?audit=<timestamp>`
  - `https://madfrog.online/api/v1/mobile/healthcheck`
  - `https://madfrog.online/clients/admin/app/`
  - `https://razblokirator.ru/health`
  - `http://162.19.242.30/health`
  - `http://162.19.242.30:80/health`
  - `https://162.19.242.30/health`
  - `http://162.19.242.30:8000/health`
  - `http://147.45.252.234/health`
  - `http://147.45.252.234:8000/health`
  - `http://147.45.252.234/clients/admin/app/`
- From NL, `nc` and `curl` probes to DE ports/endpoints.

---

Signed: GPT  
Date: 2026-05-26
