-- 014_unique_constraints.sql — last-line-of-defense uniqueness for auth identifiers.
--
-- Build-36 layered defense against duplicate accounts created when a hedged
-- client request races itself or a network retry fires before the first
-- attempt's response arrives:
--   1. Client side: single-flight on login buttons (OnboardingView).
--   2. Network side: same Idempotency-Key on every hedged leg (APIClient).
--   3. Backend side: idempotency middleware caches responses by key.
--   4. Database side: this migration. If all the above fail, postgres
--      refuses to accept the second row instead of silently creating one.
--
-- Existing partial unique indexes (init.sql + 008_email_auth.sql):
--   vpn_uuid, vpn_username, subscription_token, activation_code,
--   original_transaction_id, LOWER(email).
--
-- Added here:
--   * apple_id   — upgrade non-unique INDEX → partial UNIQUE.
--   * google_id  — new partial UNIQUE.
--   * device_id  — upgrade non-unique INDEX → partial UNIQUE.
--
-- Idempotent re-runs. If existing rows already contain duplicates the
-- CREATE UNIQUE INDEX statement will abort with the offending key —
-- investigate and merge through id_aliases (migration 012) before re-running.

BEGIN;

-- apple_id — was idx_users_apple_id (non-unique) per init.sql.
DROP INDEX IF EXISTS idx_users_apple_id;
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_apple_id_unique
    ON users (apple_id)
    WHERE apple_id IS NOT NULL;

-- google_id — no prior index; new for build-36.
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_google_id_unique
    ON users (google_id)
    WHERE google_id IS NOT NULL;

-- device_id — was idx_users_device_id (non-unique) per init.sql.
DROP INDEX IF EXISTS idx_users_device_id;
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_device_id_unique
    ON users (device_id)
    WHERE device_id IS NOT NULL;

COMMIT;
