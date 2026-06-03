-- 020_support_chat.sql
-- SUPPORT-CHAT P0 (ADR 0011): self-hosted support chat, backend core.
--
-- Two tables: one OPEN thread per user (re-open = a fresh row after the prior
-- is closed), and an append-only message log. Anonymous trial users may chat
-- too (auth via their device JWT; tighter rate-limit at the API layer), so the
-- only DB-level gate is the users(id) FK.
--
-- Retention: threads are HARD-DELETED 90 days after close by a daily purge job
-- (main.go runSupportRetention) — messages cascade. account-delete also wipes
-- them (WipeUserOnDelete + the ON DELETE CASCADE here as belt).
--
-- assigned_admin is a plain BIGINT (NO FK) in P0 — the admin inbox (P3) wires
-- the relationship to admin_users later; keeping P0 decoupled from that schema.
--
-- Migration number: ADR 0011 reserved 019, but 019 became last_vpn_seen
-- (ACTIVE-METRIC, 2026-06-03) — support chat is 020.
--
-- Idempotent: re-runs on every deploy (IF NOT EXISTS throughout).

BEGIN;

CREATE TABLE IF NOT EXISTS support_threads (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status          VARCHAR(16) NOT NULL DEFAULT 'open'
                        CHECK (status IN ('open', 'closed')),
    assigned_admin  BIGINT,                          -- P3; no FK in P0
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_message_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at       TIMESTAMPTZ
);

-- At most one OPEN thread per user. A closed thread doesn't conflict, so the
-- user's next message after a close starts a fresh thread.
CREATE UNIQUE INDEX IF NOT EXISTS idx_support_threads_user_open
    ON support_threads (user_id) WHERE status = 'open';

-- Drives the 90-day purge job.
CREATE INDEX IF NOT EXISTS idx_support_threads_closed_at
    ON support_threads (closed_at) WHERE closed_at IS NOT NULL;

CREATE TABLE IF NOT EXISTS support_messages (
    id          BIGSERIAL PRIMARY KEY,
    thread_id   BIGINT NOT NULL REFERENCES support_threads(id) ON DELETE CASCADE,
    sender      VARCHAR(8) NOT NULL
                    CHECK (sender IN ('user', 'agent', 'system')),
    body        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    read_at     TIMESTAMPTZ
);

-- Serves both "all messages in a thread" and the since=<lastId> incremental
-- fetch the SSE catch-up + poll fallback use (id is monotonic).
CREATE INDEX IF NOT EXISTS idx_support_messages_thread_id_id
    ON support_messages (thread_id, id);

COMMIT;
