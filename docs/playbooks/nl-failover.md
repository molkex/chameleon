---
title: NL failover — warm standby bring-up, promotion, failback
date: 2026-06-28
status: active   # replication LIVE 2026-06-28; promote/failback procedures below
tags: [failover, redundancy, postgres, nl, playbook]
---

# NL failover runbook

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

## 2. Promote HEL (manual, with fencing)

1. **Fence the old primary** — if NL is reachable at all, stop its writes first
   (`ssh nl 'cd /opt/chameleon && docker compose stop chameleon'`) to prevent
   split-brain. If NL is 100% unreachable (today's case), it can't accept writes anyway.
2. Promote HEL postgres: `docker exec chameleon-postgres pg_ctl promote` (or
   `SELECT pg_promote();`). Verify `pg_is_in_recovery()` → `f`.
3. HEL chameleon now writes successfully; restart it to clear any read-only-era state:
   `ssh hel 'cd /opt/chameleon && docker compose up -d --no-deps --force-recreate chameleon'`.
4. **Repoint traffic:**
   - RU API: flip MSK nginx upstream so HEL is primary
     (`upstream { server HEL:80; server NL:80 backup; }`), `nginx -t && reload`.
   - Apex (admin/landing): in Cloudflare, set the `madfrog.online` origin / LB to HEL
     (or change the A record; TTL is 300s).
   - `api.madfrog.online` A-record stays → MSK (the relay), so flipping the MSK upstream
     is enough for the RU path; no public DNS change needed there.
5. Verify: `curl https://api.madfrog.online/health` → 200; admin loads; a test sign-in works.
6. VPN exits (NL/GRA sing-box) are independent of the backend at runtime — existing
   sessions are unaffected; the promoted backend resumes user provisioning.

## 3. Fail back (after NL returns)

1. Do **not** let NL's old primary serve writes — it's now stale. Bring NL's postgres up
   as a **replica of HEL** (same `pg_basebackup` from HEL, or `pg_rewind` if WAL allows).
2. Once NL is a healthy streaming replica and caught up, schedule a calm cutover back
   (reverse §2) during low traffic, or simply **keep HEL as primary** and make NL the
   standby — there's no obligation to fail back to NL.
3. Update `docs/state/servers.yaml` + `project.yaml` to reflect the current primary.

## Guardrails

- **One primary at a time.** Never run two writable postgres. Fence before promote.
- **DNS TTL 300s** on anything that flips; verify TTL before relying on a fast cutover.
- **Drill this quarterly** on the standby (promote → verify → fail back) so it's not
  first-run during a real SEV-1.
- Backups (B2) remain the last line — replication protects against node loss, not
  against a bad migration/`DROP`. Keep daily B2 dumps.
