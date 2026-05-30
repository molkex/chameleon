---
date: 2026-05-30
severity: low
component: backend/admin API (users list)
status: resolved
---

# Admin "Registered" age inflated by +3h (created_at served without timezone)

## Symptom

In `/admin/app/users` the **Registered** column showed wrong relative ages —
a user who had just registered displayed as **"3h ago"**. Operator (in MSK,
UTC+3) read it as "server time is not MSK / clock is off".

## Investigation

Server clock is correct and **intentionally UTC** (`timedatectl` → `Etc/UTC`,
NTP synced) — that is not the bug.

Root cause was in serialization. [`backend/internal/api/admin/users.go`](../../backend/internal/api/admin/users.go)
emitted `created_at` as a naive wall-clock string `"2006-01-02 15:04"` — **no
timezone designator**. The admin SPA ([`clients/admin/src/pages/users.tsx`](../../clients/admin/src/pages/users.tsx)
`formatRegistered`) parses it with `new Date(iso)`. A zone-less date-time
string is read by the browser as **local time** (MSK), so an 08:40 UTC stamp
became 08:40 MSK = 05:40 UTC → `Date.now() - then` inflated by exactly the
UTC offset (+3h).

`last_seen` was already correct: it used `time.RFC3339` (carries the zone),
which is why only the registered age looked broken.

## Fix

`created_at` now serialized as `u.CreatedAt.UTC().Format(time.RFC3339)` →
`"2026-05-30T08:40:18Z"`, matching `last_seen` / `audit.go` / `status.go`.
Added regression test `TestToUserResponseCreatedAtIsZonedUTC`. Commit `57abe08`,
deployed to NL and verified against live `/api/admin/users` (created_at now
ends with `Z`).

## Note for future

`admins.go` (`CreatedAt.Format("2006-01-02 15:04")`) and `nodes.go`
(`created_at_fmt`) still use the naive format **on purpose** — those values are
rendered as raw display strings, not parsed by `new Date()` for relative time,
so they are fine. Only fields the SPA feeds into `new Date()` must be RFC3339.
