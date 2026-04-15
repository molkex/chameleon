-- Payment-related user fields:
--   email             — receipt email for FreeKassa (required by 54-FZ for online cash desks)
--   trial_granted_at  — timestamp when the 3-day trial was granted; NULL means trial not yet used
-- device_limit already exists from init.sql, default stays 1 for new users.

ALTER TABLE users ADD COLUMN IF NOT EXISTS email             VARCHAR(255);
ALTER TABLE users ADD COLUMN IF NOT EXISTS trial_granted_at  TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS users_email_idx ON users(email) WHERE email IS NOT NULL;

-- Ensure new users default to 1 device slot (legacy rows may have NULL).
UPDATE users SET device_limit = 1 WHERE device_limit IS NULL;
ALTER TABLE users ALTER COLUMN device_limit SET DEFAULT 1;
