---
title: System Health strip invisible (stale nginx SPA) + OOM-restarted singbox during fix
date: 2026-05-29
status: resolved
severity: P3
duration: feature invisible ~13h; ~seconds VPN drop during the OOM
tags: [deploy, nginx, spa, vite, oom, singbox, nl, infra, postmortem]
---

# Incident: stale admin SPA hid the System Health strip; rebuilding it on the box OOM'd singbox

## Symptom

After MON-04-HEALTH shipped (PR #26), the admin dashboard showed **no System
Health strip at all** — not even a loading/error state. Operator reported
"не вижу в панели данных никаких".

Confusingly, everything server-side checked out:

- `GET /api/v1/admin/stats/infra` returned **200 + full data** (cpu/ram/disk,
  p95, vpn online, 2/2 targets, `prometheus_ok: true`) — verified both via an
  authed curl on the box and via `fetch()` from the logged-in browser.
- The route was reachable through the public path (`madfrog.online/...` → 401).
- `origin/main` and the deployed source tree (`/opt/chameleon/...dashboard.tsx`)
  both contained the component **and** its `<SystemHealthStrip />` render call.

But a DOM scan of the live page found **none** of the strip's text markers, and
the served nginx bundle did **not** contain `"All systems operational"`.

## Root cause

**Two independent problems.**

1. **Stale SPA bundle.** PRs #26 (System Health strip) and #27 (payments block)
   both touched `dashboard.tsx`. The nginx image serving the SPA was built ~13h
   earlier from the **payments branch (#27) before #26 was merged**, so the
   compiled JS had the payments block but not the strip. The source on disk and
   the backend endpoint were later correct, but the **built bundle was never
   rebuilt** — so the component simply wasn't in the JS the browser ran. (The
   `grep "System Health"` that initially "found" it matched a source-map
   comment, not the rendered bundle — a false positive.)

2. **OOM during the naive fix.** A normal `docker compose build nginx` on the
   box was a no-op **cache hit** (didn't pick up the change). Forcing
   `docker compose build --no-cache nginx` ran `npm ci` + `vite build` **on the
   NL host (~2GB RAM, already running VPN + backend + Postgres + Redis +
   Prometheus + Grafana)**. Memory spiked, the OOM-killer fired, and **singbox
   was restarted** → brief VPN drop for all users (auto-recovered via
   `restart: unless-stopped`). SSH was dropped mid-build.

## Resolution

Build the SPA **off-box** — same principle the repo already uses for the Go
binary on this RAM-constrained node (`NODE_PREBUILT`):

1. Built the admin SPA locally (`vite`), confirmed the strip is in `dist`.
2. `rsync`'d the prebuilt `dist` to NL.
3. Built a **COPY-only** nginx image (`FROM nginx:alpine; COPY dist …`) — near
   zero memory — and recreated the container with `--no-build`.
4. Verified in a clean browser context: strip renders with live data
   (All systems operational · 2/2 targets · p95 5 ms · CPU 30% · RAM 55% ·
   Disk 36% · VPN online 46). Health OK, no further OOM.

## Prevention

`deploy.sh` now **builds the admin SPA locally and ships the prebuilt `dist`**;
the remote builds a COPY-only image via `clients/admin/Dockerfile.prebuilt-spa`
and recreates nginx with `--no-build`. npm/vite never run on the NL box again.

- `backend/deploy.sh` — added local `npm run build`; remote nginx build is now
  `docker build -f Dockerfile.prebuilt-spa` (COPY only) + `up --no-build`.
- `clients/admin/Dockerfile.prebuilt-spa` — new; serves prebuilt `dist`.
- The multi-stage `clients/admin/Dockerfile` is kept for CI / local self-
  contained builds.

## Lessons

- **Never run `npm`/`vite` (or any heavy build) on the NL box.** It's a 2GB
  SPoF host running prod VPN; a build OOM = VPN drop. Cross-build everything
  locally and ship artifacts (already true for Go; now true for the SPA).
- When two branches edit the same file, **a green merge does not mean the
  deployed artifact is rebuilt** — verify the *served bundle*, not just source.
- "Endpoint returns data" ≠ "UI shows data": check the rendered DOM, not only
  the API.
