---
title: HA control-plane failover via MSK-ingress single source of truth (no Patroni)
date: 2026-06-29
status: active
supersedes: none   # builds on 0012 (warm standby) — 0012 = the replica, 0013 = how we fail over to it
tags: [infrastructure, ha, failover, postgres, nl, waw]
---

# 0013 — HA failover: MSK-ingress as the single source of truth

## Context

[ADR 0012](0012-nl-redundancy-warm-standby.md) built a warm standby (Postgres streaming
replica). On **2026-06-29** NL went down a 2nd time and we executed a MANUAL failover to
WAW (promote replica → stand up backend → flip MSK), then rebuilt NL as a replica
(failback prep). It worked but was a series of hand-run steps with several live mistakes.
This ADR defines how to do it **properly** + repeatably, sized to our topology (2-3 boxes,
~380 users), explicitly NOT a heavyweight consensus stack.

## The key insight: MSK is the single API ingress

All API traffic enters through ONE place: `api.madfrog.online` (DNS) → **MSK relay nginx**
→ backend. Therefore **"who is primary" ≡ "where the MSK upstream points."** This makes a
simple, correct design possible without etcd/Patroni quorum:

- **App-layer split-brain is impossible** — only the backend MSK points to receives client
  traffic. A partitioned old primary serves nobody.
- **DB split-brain is prevented by one rule: exactly ONE chameleon backend runs at a time**
  (chameleon is the only DB writer). The failover STOPS the old chameleon (fence). Even if
  the old node is only network-partitioned (can't be stopped), it gets zero client traffic
  via MSK ⇒ zero writes ⇒ safe. The recovered node is rebuilt as a REPLICA (its divergence,
  if any, is discarded).

So we reject Patroni/etcd (over-engineered for 2-3 nodes). MSK-ingress + the one-writer
rule is the source of truth.

## Decision

### Topology
```
   api.madfrog.online ─► MSK nginx (single ingress = source of truth)
                            upstream → {active primary}:8000
   PRIMARY (WAW)  ◄── streaming replication ──►  REPLICA (NL)
   chameleon RUNNING                              chameleon STOPPED
   postgres PRIMARY                               postgres REPLICA
        ▲ watchdog (GRA, independent): primary down N min / ≥2 vantages → failover.sh
```
- **Canonical primary = WAW** (OVH, stable; NL had 2 outages in 3 days). Re-primary to NL
  only after it proves stable, via the same one command.
- Replica streams from primary over an SSH tunnel (no public 5432; WAL = all data).

### The four pillars
1. **Symmetric + pipeline-managed.** Both nodes are first-class (`deploy.sh nl|waw`), same
   stack; the standby's chameleon stays STOPPED (no crash-loop on a read-only replica).
   Replaces today's hand-assembled WAW backend.
2. **One idempotent command** `infrastructure/failover/failover.sh <target>`: fence old →
   promote target DB → start target chameleon → flip MSK (+ CF) → verify → write the
   `primary` marker. Drilled in a window, NOT run blind.
3. **Automated trigger, last.** A watchdog on GRA flips only on a SUSTAINED (N min), MULTI-
   vantage outage, behind an anti-flap lock. Built ONLY after the script is bulletproof —
   we never automate an untested operation (the 2026-06-29 lesson).
4. **Symmetric failback + CF origin failover** for the apex (admin) so it doesn't 522.

### Fencing model (why it's safe)
- Active fence: failover stops the old node's chameleon (no more writes).
- Passive fence: MSK points to exactly one backend ⇒ the other gets no traffic ⇒ no writes
  even if unreachable.
- Recovery: the returned old primary is rebuilt as a replica (discarding divergence). Never
  two writable DBs serving traffic.

## Consequences
- **Remaining SPoF = MSK itself** (single ingress). Out of scope here; mitigations later
  (2nd relay / CF apex path). The apex (CF→origin) is a partial 2nd path.
- Operational surface: the failover script + a quarterly drill + the watchdog's anti-flap
  tuning. Replication-lag + primary-health monitored (NL health-check → moved to the active
  primary; GRA external monitor on api/health).
- RPO ≈ seconds (replication); RTO = minutes (manual now → seconds once auto-trigger lands).

## Rollout (roadmap NL-RED-01 → HA phases)
- **P1 — solidify:** make WAW backend pipeline-reproducible (`deploy.sh waw` or a captured
  bring-up script), document the live topology, retire dead tunnels/slots.
- **P2 — failover.sh:** the one command + a drill.
- **P3 — watchdog:** GRA auto-trigger with anti-flap.
- **P4 — CF origin failover** for admin/landing + MSK redundancy thinking.

## Status
Active. Implementing P1-P2 now (post the 2026-06-29 manual failover, which proved the
procedure). Runbook of the exact steps: [playbooks/nl-failover.md](../playbooks/nl-failover.md).
