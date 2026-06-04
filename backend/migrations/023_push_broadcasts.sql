-- 023_push_broadcasts.sql
-- Audit log for admin push broadcasts (BROADCAST-PUSH). One row per "send to
-- all": the message + the delivery tally (total tokens at send time, sent OK,
-- failed/pruned). Lets an operator see what was blasted and to how many, and
-- guards against accidental re-sends.
CREATE TABLE IF NOT EXISTS push_broadcasts (
    id          BIGSERIAL PRIMARY KEY,
    title       TEXT NOT NULL,
    body        TEXT NOT NULL,
    total       INTEGER NOT NULL DEFAULT 0,
    sent        INTEGER NOT NULL DEFAULT 0,
    failed      INTEGER NOT NULL DEFAULT 0,
    admin_user  TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
