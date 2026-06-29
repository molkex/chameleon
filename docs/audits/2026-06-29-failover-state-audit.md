---
title: Post-failover audit — state, tests, security, doc-vs-reality (5-agent)
date: 2026-06-29
status: living   # action plan; tick as done
tags: [audit, ha, failover, tests, security, docs]
---

# 2026-06-29 — Post-failover audit + project state

5 parallel agents audited after the 2026-06-29 control-plane failover (WAW now primary).
This doc = the synthesis + action plan + project-state + roadmap check. Supersedes the
docs-reality picture in [2026-06-26 audit](2026-06-26-structure-test-hygiene-audit.md) where they conflict.

## Headline: where we are
**Stable + redundant + HA-proven, but not yet HA-automated.**
- WAW = PRIMARY backend+DB; NL = streaming REPLICA (lag ~0.05s, parity). Failover happened
  LIVE and is now scripted (`infrastructure/failover/`). Design = ADR 0013.
- Docs were badly stale (still said "NL sole backend") — **fixed this session** across
  CLAUDE.md, state/{project,servers,runtime}.yaml, arch/{overview,vpn}, playbooks, decisions/0004 status.
- Code is GREEN: `go test ./...` 17/17 pass; admin 22/22. No new code-quality debt.

## A. Doc-vs-reality drift — FIXED 2026-06-29
The docs-drift agent found 34 stale claims (NL-primary everywhere). All P0-P3 items fixed:
CLAUDE.md (servers table, deploy guard note, api upstream→WAW, "NL sole" rule), state/project.yaml
(infra/stack/health/ops/now/meta), state/servers.yaml (nl→replica, waw→primary, MSK upstream,
replication direction reversed), state/runtime.yaml (+WAW), arch/overview+vpn (Xray→sing-box-fork),
playbooks/{deploy-nl ⚠️banner, operations, nl-failover EXECUTED note}, decisions/0004 status:superseded,
arch/{mesh,target} front-matter. **deploy.sh nl now GUARDED** (refuses; ALLOW_NL_DEPLOY=1 override) —
was the #1 operational trap.

## B. Security findings (NEW) — prioritized
| Pri | Finding | Status |
|---|---|---|
| 🔴 CRIT | failover scripts: `changeme` default repl pw, 0.0.0.0 tunnel bind, StrictHostKeyChecking=no | ✅ **FIXED** this session (commit 0fc981b). Live replicator role verified NOT changeme. |
| 🟠 HIGH | H-02: `subscription_token` (full VPN-config credential) in CLUSTER peer sync wire struct (cluster/models.go:34,116) — leaks to peers in plaintext HTTP | OPEN — strip from SyncUser. (NOTE: the exit user-api push only sends clean VPNUser; the leak is cluster-to-cluster only.) |
| 🟠 HIGH | H-03: `/sub/:token` credential-in-URL (server.go:259) — token in nginx/request logs | OPEN — query-param or short-lived JWT; check logs + delete if dead. |
| 🟠 HIGH | `/metrics` unauth on :8000 (server.go:185) — exposed now WAW serves :8000 direct (no nginx). User/payment counts, route enum. | OPEN — bind 127.0.0.1 or IP-gate. |
| 🟡 MED | freekassa empty ip_whitelist silently allows all (client.go:147) — no warning logged | OPEN — log loud warning. HMAC still protects. |
| 🟡 MED | ProviderLogin/Password in cluster sync (models.go:63); diagnostic.go JWT decoded unverified (log-only) | OPEN — low-risk, note. |

## C. Tests — GREEN + map drift
- Go: 17/17 pass, coverage matches map within noise. Admin: 22/22 (map says 10 — stale). iOS: 33 test files (map says 26). The iOS data-driven flag change (38cc596) IS covered (CountryFlagTests).
- **test-map drift to fix:** admin tests 10→22 (5 files); apple test_files_count 26→33; add lifecycle/promo/push pkg entries; add PlanPricingTests.
- **NEW gap INFRA-FAILOVER-SHELLCHECK (P1):** the destructive failover scripts have NO shellcheck / `bash -n` in CI. Add a CI lint step.
- Still-open P1 money-path handler gaps (from 2026-06-26): TEST-PAYMENT-WEBHOOK, TEST-APPLE-SUBSCRIPTION-HANDLER, TEST-MOBILE-CONFIG-HANDLER.

## D. Operational debt from the failover
- ✅ done: dead `waw_standby` slot (already gone), `pg-tunnel-nl` on WAW disabled, nl2 deactivated, NL health-check cron disabled.
- TODO: WAW backend in the deploy pipeline (deploy.sh waw) + WAW nginx (symmetry + admin SPA back). MSK = single ingress SPoF. B2 restore drill (cold DR path, restore.sh rewritten 2026-06-21 but not re-tested).

## E. Project state + roadmap assessment
**Direction: ON TRACK — the redundancy bet paid off in a real incident.** Core product healthy
(auth, payments, France+Poland exits, telemetry). The big rocks:
- 🟢 Redundancy: now real (WAW↔NL replication, failover proven + scripted). Was the #1 risk; largely retired.
- 🟡 HA automation: the user's goal "any node down → auto" — needs (1) drill failover.sh, (2) GRA watchdog. Gated on a planned drill window.
- 🟡 Security: 4 HIGH/MED open (H-02/H-03/metrics/freekassa) — none block shipping, schedule them.
- 🟡 Money-path test coverage: 3 P1 handler gaps still open.
Roadmap NL-RED-01 phases reflect this (phase_2 done, phase_3 = watchdog). On-track per roadmap.

## Next-session priority order
1. (P1 sec) H-02 strip subscription_token from cluster sync + H-03 /sub audit + /metrics gate — server-only, no build.
2. (P1) INFRA-FAILOVER-SHELLCHECK CI step.
3. (HA) schedule + run the failover.sh DRILL → then the GRA watchdog.
4. (P1 tests) TEST-PAYMENT-WEBHOOK + TEST-APPLE-SUBSCRIPTION-HANDLER.
5. (P1 cleanup) deploy.sh waw + WAW nginx (admin SPA back).
6. test-map drift fixes + roadmap done-trim.
