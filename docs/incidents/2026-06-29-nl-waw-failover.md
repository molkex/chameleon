---
title: NL 2nd outage → live failover to WAW (control-plane primary flipped)
date: 2026-06-29
status: resolved
severity: SEV-1   # API down; recovered by failover
tags: [incident, failover, ha, postgres, nl, waw]
---

# 2026-06-29 — NL 2nd outage → live failover to WAW

## Summary

NL (Timeweb) went network-unreachable again (~07:05 UTC, 2nd outage in 3 days — same
ams-1 pattern as [2026-06-26](2026-06-26-timeweb-nl-ams1-outage.md)). This time the warm
standby built on [2026-06-28](../decisions/0012-nl-redundancy-warm-standby.md) was used: we
**failed the control plane over to WAW** (OVH Warsaw) live. Service stayed up (VPN never
fully dark; API restored on WAW), zero data loss. NL was then rebuilt as a streaming replica
of WAW. WAW is now the canonical primary. This validated the redundancy and produced the
codified tooling in `infrastructure/failover/` + [ADR 0013](../decisions/0013-ha-failover-msk-ingress.md).

## Timeline (UTC)
- ~07:05 — NL unreachable (GRA monitor flags it; api.madfrog.online → 504/000). VPN kept working via GRA/WAW exits (Auto urltest fails off the dead NL leg).
- ~07:40 — Decision to fail over (NL down, no ETA; the standby exists). Promote WAW's
  `chameleon-postgres-standby` (`pg_promote`, writable), bring up the chameleon backend on WAW
  (:8000, hand-assembled then captured into `waw-backend-up.sh`), flip the MSK nginx upstream
  NL→WAW (api.madfrog.online + decoy-adfox), repoint exit user-api ufw to WAW. **api/health 200, e2e-verified.**
- ~08:00 — NL's network recovered (containers stayed Up — it was a network outage, not a reboot).
- ~10:xx — Fenced returned-NL (stopped its chameleon; ufw-removed from exits; cron disabled) to
  prevent split-brain. Rebuilt NL as a streaming REPLICA of WAW (reverse tunnel + basebackup).
  Verified streaming lag ~0.05s, parity 378==378. Deactivated nl2 exit (stale roster).

## Root cause
Same as 2026-06-26: provider-side network outage of the NL box (Timeweb). Not our software.
The deeper cause we were fixing: single-NL control-plane SPoF (ADR 0004) — now mitigated.

## What worked
- ✅ The warm standby (ADR 0012) had current data (RPO ≈ seconds) — failover lost nothing.
- ✅ VPN exit redundancy (GRA/WAW) kept users connected during the API outage.
- ✅ MSK-as-single-ingress made the cutover a one-line upstream flip; the one-writer rule
  prevented split-brain.

## What was hard / lessons (→ codified)
- The WAW backend had to be hand-assembled under pressure (env file by hand, node_id, Reality
  key from the DB row). → captured into `waw-backend-up.sh`; proper `deploy.sh waw` still TODO.
- **Docker-gateway/ufw gotcha (cost ~1h):** a bridge-networked postgres replica container can't
  reach a host-loopback SSH tunnel — bind the tunnel to the docker gateway + `ufw allow` the
  docker subnet. → handled in `rebuild-replica.sh`.
- WAW serves chameleon directly on :8000 (no nginx) vs NL's nginx :80 — asymmetry encoded in
  `failover.sh`; WAW nginx + admin SPA still TODO (admin via CF still points at NL → down).
- Exit user-api ufw + the MSK user-api secret (`CHAMELEON_MSK_USER_API_SECRET`) must be
  repointed to the new primary or the roster syncer fails.

## Follow-ups
- ADR 0013 phases: DRILL `failover.sh` in a window → GRA WATCHDOG auto-trigger (the goal:
  any-node-down → automatic). P1 cleanup: `deploy.sh waw` + WAW nginx. CF apex origin failover.
- Decide canonical primary long-term (currently WAW — NL had 2 outages). MSK is now the
  remaining single ingress SPoF.
