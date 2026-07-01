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

---

## Addendum (2026-06-29, +2h): SPB second decoy leg left on dead NL upstream → 502

**Symptom:** MSK RU-auth monitor (`ru-auth-healthcheck.sh`) fired every 5 min:
`🟠 RU decoy redundancy degraded — one relay down — primary=200 decoy_msk=200 decoy_spb=502`.

**Root cause:** the hand-failover (and `failover.sh` as written) flipped only the **MSK**
nginx upstreams (api + decoy) → WAW:8000. The **SPB second decoy leg**
(`/etc/nginx/conf.d/decoy-adfox.conf`, RU-DECOY-2ND) still pointed at `147.45.252.234:80`
(NL), whose backend is stopped post-failover → 502. Two compounding gaps:
1. SPB decoy upstream not repointed (SPB is a password-auth box, off the SSH key → omitted).
2. WAW ufw only allowed MSK (217.198.5.52) → 8000; SPB (185.218.0.43) was never whitelisted,
   so even after repointing, SPB→WAW:8000 timed out until the ufw rule was added.

Auth was NOT down — CF + MSK decoy both 200. This was loss of the *redundancy* (SPOF restored),
exactly the state the 2nd decoy leg exists to prevent.

**Fix (live + verified, decoy_spb=200 from MSK vantage):**
- WAW: `ufw allow from 185.218.0.43 to any port 8000 proto tcp`.
- SPB: repoint `/etc/nginx/conf.d/decoy-adfox.conf` 147.45.252.234:80 → 217.182.74.70:8000, reload.

**Codified so it can't recur:** `failover.sh` now (a) step 4b opens the new-primary backend
port to BOTH relays (MSK + SPB) via ufw, and (b) step 5b flips the SPB decoy upstream too
(best-effort via sshpass + `SPRINTBOX_VPS_PASSWORD`; skips with a warning if unavailable).
Repo decoy configs (`infrastructure/{msk,spb}-relay/decoy-adfox.conf`) synced to WAW:8000
(closes part of the MSK/SPB-config-drift DR-gap, roadmap RELAY-CONFIG-DRIFT).

---

## Addendum (2026-07-01): web layer made independent of NL (CF apex origin → WAW)

**Symptom:** `https://madfrog.online/admin/app/` (and the apex landing) returned
Cloudflare **522** — origin still NL (147.45.252.234), whose nginx/backend is
stopped post-failover. The admin UI had no working URL (the api-host bypass
`api.madfrog.online/admin/app/` 404s — WAW's :8000 backend serves the API only,
not the SPA static). This was ADR 0013 P1/P4 left open.

**Fix (live + verified):**
- Built the admin SPA (`clients/admin`, base `/admin/app/`, API relative `/api/v1`)
  and shipped it + `backend/landing` + `backend/nginx.conf` to WAW `~/chameleon-web`.
- Ran `chameleon-nginx` (nginx:1.27-alpine, host net :80) proxying
  `/api,/health,/sub` → `127.0.0.1:8000` (WAW backend), serving landing at `/` and
  the SPA at `/admin/app/` — the exact same content NL's nginx served.
- `ufw allow :80` from Cloudflare IPv4 ranges only (origin not exposed wide).
- Cloudflare apex `madfrog.online` + `www` A-records flipped 147.45.252.234 → 217.182.74.70 (proxied).

Verified through CF: `/`, `/admin/app/`, `/health`, `/api/v1/mobile/healthcheck`,
`/app/`, AASA all 200; real admin login `POST /api/v1/admin/auth/login` → 200.
The public site is now independent of NL.

**Codified:** `infrastructure/failover/waw-web-up.sh` reproduces the whole web
layer (build → ship → run nginx → ufw → optional `FLIP_CF=1` apex origin flip).
State synced: servers.yaml (WAW web_frontend role), domains.yaml (apex/www/api
origins), CLAUDE.md, roadmap HA-WAW-PIPELINE.

**Still open:** proper `deploy.sh waw` for the backend (interim: `waw-backend-up.sh`);
grafana/mdfrog.site/razblokirator.ru still point at NL; MSK remains the single
RU-API ingress SPoF.
