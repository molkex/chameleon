---
title: Mobile "Сессия истекла" logout loop — multi-leg refresh race vs single-use token
date: 2026-07-01
status: resolved
severity: SEV-2   # no data loss; users bounced to re-login (subscription intact)
tags: [incident, auth, mobile, refresh-token, failover, redis]
---

## Symptom
After the 2026-06-29 NL→WAW failover, users hit the "Войдите снова / Сессия истекла"
screen and were bounced to re-login (Apple / magic-link). Account + subscription
intact — it was a session problem, not data loss. WAW backend logs showed a steady
stream of `mobile refresh: token reuse attempt` across many users (12351, 159283,
159080, 159145, 158987, …), each followed by `POST /api/mobile/auth/refresh → 401`.

## Root cause
The iOS client fans a single token refresh out over **several transport legs**
simultaneously (Cloudflare primary + MSK/SPB clean-SNI decoy relays) to survive RU
SNI filtering. Refresh tokens are **single-use with rotation** (Redis `mrt:used:<hash>`
SET NX). So the FIRST leg to arrive rotates the token; every other leg presenting the
SAME token gets `redis.Nil` → 401 "token reuse attempt". When a loser leg's 401
surfaced before the winner's 200, the app treated the session as dead — and the
now-consumed token 401s forever → logout loop.

Not caused by the same-day SPB decoy fix — the reuse-401s predate it (CF + MSK alone
already raced; 7 events before 11:35Z, 4 after). The failover (fresh WAW redis + longer
MSK→WAW RTT widening the race) surfaced it at scale.

This is the SERVER-side complement to the already-known client-side pain
(AUTH-REFRESH-ROTATE, 2026-06-17: the client must keep the rotated token, not the one
it sent). The client fix alone can't help when a *different leg* consumed the token.

## Fix
OAuth 2.0 "reuse leeway" / Auth0-style refresh-rotation grace window
(`backend/internal/api/mobile/auth.go`, `RefreshToken`):
- On rotation, cache the issued pair in Redis at `mrt:issued:<hash>` for **30s**.
- A duplicate presentation of the same token while that cache exists replays the
  **exact same** rotated pair (200) — so all racing legs converge on one valid pair.
- A genuine reuse *after* the window (issued cache expired, used-marker still present
  30d) still returns 401 — rotation + reuse detection intact.
- Also: roll back the used-marker if pair creation fails (don't strand a token);
  made the optional subscription lookup nil-safe.

Tests: `refresh_grace_test.go` (miniredis) — grace replay returns identical pair;
reuse after grace window → 401.

Deployed to WAW via `waw-backend-up.sh`; verified live: register → refresh → refresh
(same token) now returns 200 twice with `mobile refresh: grace-window replay` in the
log instead of `token reuse attempt`.

## Follow-ups
- Consider a random `jti` on refresh tokens so rotation always yields a distinct token
  (today two refreshes within the same wall-clock second produce an identical token —
  harmless in prod because refreshes are minutes apart, but not robust).
- Client (next build): don't hard-logout on a single leg's 401 if another leg 200s;
  keep racing refresh to a single leg where possible.
