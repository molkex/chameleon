-- 027_lifecycle_reminders.sql — A1 lifecycle re-engagement (PRODUCT-MATURITY-LOOP, 2026-06-21).
--
-- Records which lifecycle reminder was sent to which user for which subscription
-- expiry, so the daily sweep fires each reminder EXACTLY ONCE per subscription
-- cycle. The unique index keys on (user_id, kind, expiry_ref): a re-subscription
-- moves subscription_expiry to a new value → a fresh expiry_ref → the user is
-- eligible for the new cycle's reminders again. Idempotent re-runs.
--
-- kind: expiring_soon | expired_recent | expired_winback
CREATE TABLE IF NOT EXISTS lifecycle_reminders (
    id          BIGSERIAL PRIMARY KEY,
    user_id     BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind        TEXT        NOT NULL,
    expiry_ref  TIMESTAMPTZ NOT NULL,        -- the subscription_expiry this reminder concerned
    channels    TEXT        NOT NULL DEFAULT '',  -- which channels actually delivered (e.g. "push,email")
    sent_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_lifecycle_reminders_once
    ON lifecycle_reminders (user_id, kind, expiry_ref);

CREATE INDEX IF NOT EXISTS idx_lifecycle_reminders_user
    ON lifecycle_reminders (user_id);
