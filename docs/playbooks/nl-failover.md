---
title: NL failover — warm standby bring-up, promotion, failback
date: 2026-06-28
status: active
tags: [failover, redundancy, postgres, nl, playbook]
---

# NL failover runbook

> ⚠️ **EXECUTED 2026-06-29 — WAW is now the live PRIMARY; NL is the replica.**
> §2 below describes what was done during the failover. §0 (HEL bring-up) is
> historical/superseded — WAW (OVH Warsaw) was used instead of Hetzner Helsinki.
> For the current live topology see [`../state/runtime.yaml`](../state/runtime.yaml)
> and [ADR 0013](../decisions/0013-ha-failover-msk-ingress.md).

Implements [ADR 0012](../decisions/0012-nl-redundancy-warm-standby.md). The standby is
**WAW (OVH Warsaw, 217.182.74.70)** — not Hetzner (reg failed) — running the same
sing-box exit + a Postgres streaming replica of NL. **Manual failover only (v1)** — see
ADR 0012 for the split-brain rationale.

> **STATUS 2026-06-28 — replication is LIVE.** Actual wiring (replaces the generic §0 below):
> - NL primary postgres:16-alpine (127.0.0.1:5432), role `replicator` + slot `waw_standby`,
>   pg_hba `host replication replicator 172.19.0.0/16 scram-sha-256`.
> - Encrypted transport = **SSH tunnel** `pg-tunnel-nl.service` (autossh on WAW, key
>   ~/.ssh/nl_tunnel restricted on NL to `permitopen=127.0.0.1:5432`): WAW 127.0.0.1:15432 → NL 127.0.0.1:5432.
> - WAW standby = container `chameleon-postgres-standby` (postgres:16-alpine, --network host,
>   vol chameleon-pgdata-standby), built via `pg_basebackup -h127.0.0.1 -p15432 -U replicator -R -S waw_standby -X stream`.
> - Verify: NL `select * from pg_stat_replication` (state=streaming); WAW `select pg_is_in_recovery()` (t).
> Still TODO: MSK upstream backup + the promote automation (§2) + a drill.

## 0. Standby bring-up (one-time, Phase 1)

Prereq: a fresh non-Timeweb VPS (Hetzner Helsinki CX/CAX, Debian 12), Docker installed,
this repo present, `~/.secrets.env` available to the deploy.

1. Deploy the stack idle (DB will be replaced by a replica):
   - Add a `hel` node to `backend/deploy.sh` node registry (SSH, dir, node-id `hel-1`, SNI).
   - `cd backend && ./deploy.sh hel` (brings up chameleon/postgres/redis/nginx; prometheus/grafana optional).
2. Convert HEL postgres into a **streaming replica** of NL:
   - On NL: ensure `wal_level=replica`, `max_wal_senders>=3`, a `replicator` role, and
     `pg_hba.conf` allows HEL's IP for `replication`. Reload.
   - On HEL: stop the postgres container, wipe its `pgdata`, then
     `pg_basebackup -h <NL_IP> -U replicator -D <pgdata> -Fp -Xs -P -R` (the `-R` writes
     `standby.signal` + `primary_conninfo`). Start postgres → it streams from NL, read-only.
   - Verify: on NL `SELECT * FROM pg_stat_replication;` shows HEL `state=streaming`;
     on HEL `SELECT pg_is_in_recovery();` → `t`.
3. HEL chameleon runs but writes fail (read-only DB) — that's expected until promotion.
4. Redis on HEL is its own instance (cache/pubsub rebuild on promotion; no replication needed).
5. Static admin/landing built into HEL nginx (same artifacts as NL).

## 1. Detect + decide (when NL looks down)

1. Confirm from **≥2 independent off-NL vantages** (MSK + GRA):
   ```
   ssh msk 'ping -c3 147.45.252.234; for p in 22 80 443; do timeout 5 bash -c "echo >/dev/tcp/147.45.252.234/$p" && echo $p ok || echo $p fail; done'
   ```
2. Check the **provider** first: Timeweb Cloud Alerts TG + `GET /account/status`
   (`is_blocked`) + `/servers/6379091`. If it's a known Timeweb mass incident with a
   short ETA, **waiting may beat failing over** (failover has failback cost). Fail over
   when: NL down with no ETA, or down > ~15–20 min, or data-loss risk.

## 2. Promote WAW (manual, with fencing) — EXACT commands

Standby = `chameleon-postgres-standby` on WAW (`debian@217.182.74.70`, sudo docker). The
WAW app tier (chameleon/redis/nginx) is NOT running in steady state — only the DB replica
+ the sing-box exit are. Promote = make the replica writable, then bring up the app tier.

1. **Fence the old primary.** If NL is reachable at all, stop its writes first:
   `ssh -i ~/.ssh/claude-code-ssh-key root@147.45.252.234 'cd /opt/chameleon/backend && docker compose stop chameleon nginx'`.
   If NL is 100% unreachable (the 2026-06-26 case), it can't accept writes — skip.
2. **Promote the replica** (WAW becomes a writable primary):
   `ssh ... debian@217.182.74.70 'sudo docker exec chameleon-postgres-standby psql -U chameleon -d chameleon -c "select pg_promote()"'`
   Verify `pg_is_in_recovery()` → `f`. The SSH tunnel + replicator slot are now moot.
3. **Bring up the WAW app tier** pointed at the local (now-writable) DB on 127.0.0.1:5432:
   - redis: `sudo docker run -d --name chameleon-redis --network host --restart always redis:7-alpine redis-server --requirepass "$CHAMELEON_REDIS_PASSWORD" --maxmemory 128mb --maxmemory-policy allkeys-lru`
   - chameleon + nginx: deploy from the repo. `deploy.sh` is NL-shaped (root, plain `docker`);
     for WAW either add a `waw` node (debian@ + sudo) OR run the prebuilt binary + a WAW
     compose (no postgres service — the standby already serves :5432; redis above; chameleon
     env DATABASE_URL=postgres://chameleon:PW@127.0.0.1:5432, REDIS_URL=127.0.0.1:6379).
     ⚠️ NOT pre-built/drilled — see "Drill" note. This is the one untested gap; stage it
     before relying on a fast RTO.
4. **Repoint traffic:**
   - RU API (the main path): on MSK, flip the upstream NL→WAW:
     `ssh ... root@217.198.5.52 "sed -i 's#147.45.252.234:80#217.182.74.70:80#g' /etc/nginx/sites-available/api.madfrog.online && nginx -t && systemctl reload nginx"`
     (also `decoy-adfox` if RU sign-in must follow). Open WAW ufw :80 from MSK first.
   - Apex (admin/landing): in Cloudflare set the `madfrog.online` origin to 217.182.74.70.
   - `api.madfrog.online` A-record stays → MSK, so the MSK flip is enough for the API path.
5. Verify: `curl https://api.madfrog.online/health` → 200; admin loads; test sign-in.
6. VPN exits (NL/GRA/WAW sing-box) are independent of the backend at runtime — existing
   sessions unaffected; the promoted backend resumes user provisioning + roster sync.

## 3. Fail back (after NL returns)

1. NL's old primary is now STALE — do not let it serve writes. Rebuild NL's postgres as a
   **replica of WAW** (`pg_basebackup` from WAW, or `pg_rewind` if WAL lines up).
2. Once NL is a caught-up streaming replica, either cut back to NL (reverse §2 during low
   traffic) or **keep WAW as primary** and leave NL as the standby — no obligation to flip back.
3. Update `docs/state/servers.yaml` + `project.yaml` to reflect the current primary.

## Drill status (2026-06-28)

Replication is LIVE + monitored (NL health-check alerts if the standby stops streaming or
lag > 120s). A real promote DIVERGES the replica (you must re-`pg_basebackup` afterward), so
it is NOT exercised casually — run it as a **planned drill in a low-traffic window**, and
before relying on a fast RTO, **pre-stage step 3** (the WAW app-tier image + compose) so
promote is `pg_promote` + `compose up`, not a cold deploy.

## Guardrails

- **One primary at a time.** Never run two writable postgres. Fence before promote.
- **DNS TTL 300s** on anything that flips; verify TTL before relying on a fast cutover.
- **Drill this quarterly** on the standby (promote → verify → fail back) so it's not
  first-run during a real SEV-1.
- Backups (B2) remain the last line — replication protects against node loss, not
  against a bad migration/`DROP`. Keep daily B2 dumps.
