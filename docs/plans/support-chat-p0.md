---
title: SUPPORT-CHAT — P0 backend core, detailed implementation plan
date: 2026-06-03
status: |
  P0 mostly DONE + DEPLOYED to NL (2026-06-03). Steps 1,2,3,5 (bb63e53, bf438d2,
  03c30c9, 091f33d) + step 4a NL deploy (migration 020 applied, endpoints live,
  NL nginx SSE location d073b38). Tables renamed support_chat_* (54f0b83) to dodge
  a LEGACY support_messages table that exists on NL but isn't in the repo migrations.
  REMAINING: step 4b MSK/SPB relay nginx SSE block (not in repo → SSH; deferred to
  P1, no SSE consumer yet) + P1 web widget (first user-visible piece).
  ⚠️ Landmine for future migrations: NL has legacy tables NOT in repo migrations —
  `\dt` before CREATE TABLE on a generic name.
decision_ref: decisions/0011-self-hosted-support-chat.md
roadmap: SUPPORT-CHAT (next.support)
---

# SUPPORT-CHAT · P0 backend core — implementation plan

Self-hosted, real-time support chat on our own stack (Go+Echo+pgx+Redis), per
ADR 0011. **P0 = the backend** the iOS/macOS webview (P1/P2) and admin inbox (P3)
will all talk to. No client UI in P0.

## Decisions locked (2026-06-03)
- **Who can chat:** everyone, *including anonymous trial* device accounts. They
  already carry a device JWT, so `requireAuth` gates the routes; anon
  (`auth_provider IS NULL`) just gets a **tighter rate-limit tier**.
- **Push:** *fast-follow* — P0 is foreground/SSE only. APNs is P4, separate.
- **Retention:** **hard-delete 90 days after a thread is closed** (daily purge job).
- **Migration number:** ADR 0011 said `019`; that's now taken (`last_vpn_seen`) →
  support-chat starts at **`020`**.

## ⚠️ Gating before the NEXT App Store submit (not P0 code, but blocks release)
Storing chat messages contradicts `legal.privacy` ("we don't store usage
metadata"). **Update the privacy policy text + the ASC privacy nutrition label**
(Customer Support → User Content) before submitting any build that ships chat
(Guideline 5.1.1). Tracked as a release-checklist item, not a code task.

---

## 1. Migration `020_support_chat.sql`
```sql
BEGIN;
CREATE TABLE IF NOT EXISTS support_threads (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status          VARCHAR(16) NOT NULL DEFAULT 'open',     -- open | closed
    assigned_admin  BIGINT REFERENCES admins(id),            -- nullable; P3 uses it
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_message_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at       TIMESTAMPTZ                               -- set on close; drives 90d purge
);
-- One OPEN thread per user (re-open by clearing closed_at / new row after close).
CREATE UNIQUE INDEX IF NOT EXISTS idx_support_threads_user_open
    ON support_threads (user_id) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS idx_support_threads_closed_at
    ON support_threads (closed_at) WHERE closed_at IS NOT NULL;

CREATE TABLE IF NOT EXISTS support_messages (
    id          BIGSERIAL PRIMARY KEY,
    thread_id   BIGINT NOT NULL REFERENCES support_threads(id) ON DELETE CASCADE,
    sender      VARCHAR(8) NOT NULL,                          -- user | agent | system
    body        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    read_at     TIMESTAMPTZ                                   -- read receipts (P1+ improvement)
);
CREATE INDEX IF NOT EXISTS idx_support_messages_thread_id_id
    ON support_messages (thread_id, id);                     -- list + since= pagination
COMMIT;
```
- ON DELETE CASCADE on both FKs = account-delete wipe is structurally guaranteed
  (belt: also explicit in `WipeUserOnDelete`, §3).
- `(thread_id, id)` index serves `since=<lastId>` incremental fetch (monotonic id).

## 2. DB layer — `backend/internal/db/support.go`
| Method | Purpose |
|---|---|
| `OpenOrGetThread(ctx, userID) (*SupportThread, error)` | upsert the user's open thread (uses the partial unique index) |
| `AppendMessage(ctx, threadID, sender, body) (*SupportMessage, error)` | insert + bump `last_message_at`; returns the row (for fan-out) |
| `ListMessages(ctx, threadID, sinceID, limit) ([]SupportMessage, error)` | `WHERE thread_id=$1 AND id>$2 ORDER BY id LIMIT $3` |
| `ThreadOwnedBy(ctx, threadID, userID) (bool, error)` | authz guard on every read/write |
| `CloseThread(ctx, threadID)` / `ReopenThread` | admin/user lifecycle; stamps/clears `closed_at` |
| `PurgeClosedThreadsOlderThan(ctx, d) (int64, error)` | `DELETE … WHERE status='closed' AND closed_at < NOW()-$1` (cascade kills messages) |
- Extend **`WipeUserOnDelete`** (db/users.go): add `DELETE FROM support_threads WHERE user_id=$1` (messages cascade) inside its existing tx, so account deletion removes chat too.

## 3. Mobile API — `backend/internal/api/mobile/support.go`
Registered in `RegisterRoutes` (routes.go) under a `requireAuth` group, EXCEPT
the SSE stream (see §4). All JSON; reuse existing `ErrorResponse`.
| Method/Path | Notes |
|---|---|
| `POST /support/messages` | body `{text}`. Validates len (≤ 4000), opens/gets thread, AppendMessage(sender=user), publishes to Redis, returns the message. Reuses `mw.Idempotency` (already on the mobile group) so retries don't double-post. |
| `GET /support/messages?since=<id>` | poll/catch-up fallback for when SSE drops. Returns messages + thread status. |
| `GET /support/thread` | current open thread meta (id, status, last_message_at, unread count). |
| `GET /support/stream` (SSE) | live message stream — see §4. |
| `GET /support/chat-token` | issues a short-lived (≤10 min) signed token, audience `support-sse`, claim = user_id. The hosted webview's `EventSource` can't set Authorization headers, so the SSE auth comes via `?token=` (validated by a tiny token verifier, NOT the normal Bearer middleware). |
- **Rate-limit tiers** (anti-abuse, anon decision): a per-user limiter keyed by
  `claims.UserID`. authed (apple/google/email) = N msg/min; anon
  (`auth_provider IS NULL`) = N/3 + a max of 1 open thread + a daily message cap.
  Implement as a small middleware in front of `POST /support/messages` (Redis
  INCR with TTL, same pattern as the existing `mw.RateLimit`).

## 4. Realtime — Redis pub/sub + SSE
- Channel `support:thread:{threadID}`. `AppendMessage` (from user OR admin) →
  `redis.Publish(channel, json(message))`. Reuses the cluster pub/sub pattern.
- **SSE handler** (`GET /support/stream`): validate `?token=`, resolve user →
  open thread, `SUBSCRIBE support:thread:{id}`, write each message as
  `data: <json>\n\n`, plus a `:keepalive` comment every ~20s. On connect, replay
  any messages newer than the client's `Last-Event-ID` / `?since=`.
- **Three infra fixes (ADR 0011 sse_gotchas — verified anchors):**
  1. `http.Server.WriteTimeout = 30s` (cmd/chameleon/main.go:370) would kill the
     stream. **Do NOT set it to 0 globally** — instead, per-request:
     `http.NewResponseController(w).SetWriteDeadline(time.Time{})` inside the SSE
     handler (Go 1.20+; keeps the 30s protection for every other route).
  2. Echo `ContextTimeoutWithConfig{30s}` (internal/api/server.go:152) cancels
     the request ctx. Register the SSE route on a group that **skips** it (a
     `Skipper` that returns true for `/support/stream`, or a separate group
     without the timeout middleware).
  3. `mw.Idempotency` + the SSE route don't mix (it buffers) — exclude the stream
     from it too.
  4. **nginx** (NL + relays): add a `location /api/v1/mobile/support/stream`
     with `proxy_buffering off; proxy_read_timeout 1h; proxy_http_version 1.1;
     add_header X-Accel-Buffering no;`. Route via `api.madfrog.online` (bypass
     CF, which buffers/limits SSE). ⚠️ **MSK relay nginx config is NOT in the
     repo** → fetch from 217.198.5.52, edit, apply, and commit a copy. Deploy blocker.

## 5. Retention job
- `go runSupportRetention(ctx, db, 24h)` in main.go (mirrors `runTrafficCollector`):
  daily `PurgeClosedThreadsOlderThan(ctx, 90*24h)`, logs the deleted count.

## 6. Tests (integration-tagged, testcontainers PG)
`backend/internal/db/support_test.go`: open-thread dedup (partial unique index),
append + last_message_at bump, list since=, close→reopen, purge-90d (closed only),
WipeUserOnDelete cascades threads+messages. API (`mobile`): authz (other user's
thread → 403), anon vs authed rate-limit tiers, idempotent POST, chat-token
verify (good/expired/wrong-audience). SSE: minimal handler unit (deadline cleared,
timeout skipper applied); full stream = manual/integration.

## 7. Commit sequence (each independently green)
1. migration 020 + `db/support.go` + `support_test.go` (+ WipeUserOnDelete extension).
2. mobile REST (`POST/GET messages`, `GET thread`, chat-token) + rate-limit tiers + tests.
3. Redis fan-out + SSE handler + the 3 app-side infra fixes (WriteTimeout/Echo-ctx/Idempotency).
4. nginx SSE location (NL via deploy.sh; MSK/SPB hand-applied + committed copy).
5. retention job + main.go wiring.

Est. ~9 dev-days (ADR 0011 P0 estimate).

## Out of P0 (later phases, ADR 0011)
P1 hosted web widget (chat.madfrog.online) · P2 Apple WKWebView embed (replaces
the `mailto:` in SettingsView.swift) · P3 admin SPA inbox · P4 APNs push ·
P5 Telegram bridge (@MadFrogRobot) · P6 Android/Windows (same widget; blocked on
the platform-stack decision).
