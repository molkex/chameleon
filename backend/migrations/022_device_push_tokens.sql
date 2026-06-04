-- 022_device_push_tokens.sql
-- SUPPORT-CHAT push notifications (ADR 0011 follow-up, P4).
--
-- One row per (device) APNs token. The iOS client registers its token via the
-- mobile /push/register endpoint; when a support AGENT replies, the backend
-- looks up every token for the thread's owner and sends an APNs alert.
--
-- token is UNIQUE: a device that re-registers (or moves to another account)
-- upserts onto the same row (DO UPDATE SET user_id=excluded.user_id). The
-- user_id FK cascades on account delete so a wiped account leaves no tokens.
--
-- This name is new + repo-managed (NL carries some legacy tables), so IF NOT
-- EXISTS here is pure idempotency, not a collision dodge.
--
-- Idempotent: re-runs on every deploy.

CREATE TABLE IF NOT EXISTS device_push_tokens (
    id          BIGSERIAL PRIMARY KEY,
    user_id     BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token       TEXT NOT NULL UNIQUE,
    platform    TEXT NOT NULL DEFAULT 'ios',
    environment TEXT NOT NULL DEFAULT 'production',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_device_push_tokens_user ON device_push_tokens(user_id);
