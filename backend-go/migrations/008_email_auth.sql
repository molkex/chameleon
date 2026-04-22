-- 008_email_auth.sql — email-based authentication (magic links + optional password).
--
-- Adds:
--   users.email              — primary email when user signs up/backs up via email
--   users.email_verified_at  — non-null once user proved control of the address
--   users.password_hash      — reserved for classic email+password path (unused by MVP)
--
-- Plus a magic_tokens table that backs the passwordless flow used by every
-- sign-in path (email, or backup path after Apple/Google).

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS email              TEXT,
    ADD COLUMN IF NOT EXISTS email_verified_at  TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS password_hash      TEXT;

-- Partial unique index: only active non-null emails must be unique. Allows
-- multiple NULL emails (users without one) without collision.
CREATE UNIQUE INDEX IF NOT EXISTS users_email_unique_lower
    ON users (LOWER(email))
    WHERE email IS NOT NULL;

CREATE TABLE IF NOT EXISTS magic_tokens (
    id           BIGSERIAL PRIMARY KEY,
    -- SHA-256 hex of the random token. Never store raw tokens — if the DB
    -- leaks we don't want attacker to log in as anyone.
    token_hash   TEXT        NOT NULL UNIQUE,
    -- Target email the link was issued for. Lower-cased on insert.
    email        TEXT        NOT NULL,
    -- If null, this is a fresh-sign-up (no user yet). On verify, we create
    -- a user and bind it. If non-null, this is a login for existing user.
    user_id      INTEGER     REFERENCES users(id) ON DELETE CASCADE,
    -- Where the request came from — "apple_signup", "google_signup",
    -- "email_login", "email_signup". Logged, not used for auth.
    purpose      TEXT        NOT NULL,
    -- Short-lived. Default 15 minutes. Consumed via UPDATE ... WHERE used_at IS NULL.
    expires_at   TIMESTAMPTZ NOT NULL,
    used_at      TIMESTAMPTZ,
    created_ip   INET,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS magic_tokens_email_idx ON magic_tokens (LOWER(email));
CREATE INDEX IF NOT EXISTS magic_tokens_expires_idx ON magic_tokens (expires_at)
    WHERE used_at IS NULL;

-- Rate-limit hint: a single email can't request more than N links/minute.
-- Enforced at handler level via COUNT(*) query; index makes it fast.
