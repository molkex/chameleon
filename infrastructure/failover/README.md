# Control-plane failover tooling

Implements [ADR 0013](../../docs/decisions/0013-ha-failover-msk-ingress.md). Runbook:
[playbooks/nl-failover.md](../../docs/playbooks/nl-failover.md).

**Model:** the MSK relay nginx is the single API ingress, so *who is primary = where the
MSK upstream points*. Exactly one `chameleon` backend runs at a time (the only DB writer) →
no split-brain. The recovered old primary is rebuilt as a replica (its divergence discarded).

## Scripts

| Script | What | Safe? |
|---|---|---|
| `failover.sh status` | show current primary (per MSK) + api health | ✅ read-only |
| `failover.sh <waw\|nl> [--yes]` | fence old → promote target DB → start target chameleon → repoint exit ufw → flip MSK → verify | ⚠️ destructive |
| `rebuild-replica.sh <replica> <primary>` | wipe + rebuild a node as a streaming replica of the primary (failback / restore redundancy) | ⚠️ wipes replica DB |

## Current topology (2026-06-29, post-failover)
- **PRIMARY = WAW** (217.182.74.70): `chameleon-failover` on :8000, `chameleon-postgres-standby` (promoted), redis. MSK → WAW:8000.
- **REPLICA = NL** (147.45.252.234): `chameleon-postgres` streaming from WAW (lag ~0.05s). chameleon STOPPED.
- Exit user-api ufw (:15380 on GRA/WAW) points to the primary (WAW); old primary removed.

## Gotchas (learned the hard way 2026-06-29)
- A **bridge-networked** postgres container can't reach a host-loopback SSH tunnel. Bind the
  tunnel to the docker **gateway** (`-o GatewayPorts=yes -L 0.0.0.0:15432`) and `ufw allow`
  the docker subnet → 15432. `rebuild-replica.sh` does this automatically.
- WAW backend serves chameleon **directly on :8000** (no nginx); NL serves via **nginx :80**.
  `failover.sh` encodes the per-node MSK target. (P1 cleanup: give WAW an nginx too for symmetry + the admin SPA.)
- The MSK user-api uses `CHAMELEON_MSK_USER_API_SECRET` (not `USER_API_SECRET`).
- After promoting, re-point the exit user-api ufw to the new primary or the syncer can't push.

## TODO (ADR 0013 phases)
- P1 — make WAW backend pipeline-reproducible (`deploy.sh waw` / a captured bring-up), add WAW nginx, retire dead `waw_standby`/old tunnels.
- P2 — drill `failover.sh` in a window.
- P3 — GRA watchdog auto-trigger (sustained, multi-vantage, anti-flap) → `failover.sh`.
- P4 — Cloudflare apex origin failover (admin) + MSK ingress redundancy.
