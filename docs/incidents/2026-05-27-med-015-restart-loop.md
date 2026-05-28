---
title: MED-015 — chameleon restart loop after admin save wiped reality_private_key
date: 2026-05-27
status: resolved
severity: P1
duration: ~7 min outage on NL
tags: [med-015, postmortem, chameleon, admin, reality]
---

# Incident: chameleon restart loop after admin Servers save wiped reality_private_key

## Symptom

NL `chameleon` container went into `Restarting (1)` loop. `/health` returned 000 for ~7 min. New users couldn't `/auth/register` or `/api/v1/mobile/config`.

sing-box (separate container, own config file) kept running — active VPN sessions survived.

Fatal startup line:

```
fatal: reality private key not found — set it in vpn_servers DB table or REALITY_PRIVATE_KEY env var
```

`vpn_servers.reality_private_key` for local node row (`key='nl2'`) was empty:

```sql
SELECT length(reality_private_key) FROM vpn_servers WHERE key='nl2'; -- 0
```

## Root cause

The admin SPA `PUT /api/v1/admin/servers/:id` form posts every field at save time, including the `reality_private_key` field which the UI hides for security. With nothing visible to type, the form sends `reality_private_key: ""`.

`db.UpdateServer` did `SET reality_private_key = $10` without a NULLIF guard. The empty string overwrote the stored key.

At next chameleon restart (any `deploy.sh nl` or container restart), startup-validation read the now-empty key → fatal.

Trail in `admin_audit_log`:

```
15 | 2026-05-27 19:40:06 | server.update | 72.56.108.130 | id=93 key=nl2 host=147.45.252.234 port=443 active=true
```

## Recovery (immediate)

1. Pulled the running key out of `/etc/singbox/singbox-config.json` on the NL box (sing-box keeps its own copy and was still alive).
2. `UPDATE vpn_servers SET reality_private_key='<key>' WHERE key='nl2'`.
3. Container came up healthy on next restart attempt.

## Permanent fix

`internal/db/servers.go` `UpdateServer` now wraps three secret fields with `COALESCE(NULLIF($N, ''), <column>)`:

- `reality_public_key`
- `reality_private_key`
- `provider_password`

An empty payload string now preserves the stored value instead of overwriting it. Same guard pattern that `UpsertServerByKey` already had — applied to `UpdateServer` too.

Regression test: `TestUpdateServerPreservesSecrets` (integration tag) — passes empty strings for the three fields and asserts the stored values are unchanged.

## Lessons

- **Sensitive admin form fields hidden from UI must not be sent as `""`** by default. Either:
  - Don't include the field in the PATCH payload (preferred — use omitempty patterns).
  - OR server-side COALESCE-NULLIF guard (what we did, retroactively).
- **`UpsertServerByKey` had this guard; `UpdateServer` didn't.** Lockstep failure modes — when two functions both write the same column, they need identical defensive logic. Audit checklist next time we add a write path.
- **Cluster sync intentionally does not propagate `private_key`** between peers (see `cluster/models.go SyncServer`) — that meant only one UPDATE handler could brick the box. Single ingress = single point of bug, also single point of fix.

## Don't retry

- **Do not rotate keys as the fix when chameleon is in restart-loop.** New pub_key won't reach iOS clients (because `/config` API is down), they keep handshaking with stale pub_key → silent auth failures. Restore old key first; rotate later if needed.
