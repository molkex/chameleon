-- 018_trial_granted_at.sql
-- SEC-01 (2026-06-01): stop infinite free trials per identity.
--
-- Bug: AppleSignIn / GoogleSignIn re-granted a fresh 3-day trial on EVERY
-- sign-in whose subscription had lapsed (auth.go / auth_google.go). Since the
-- only gate was `subscription_expiry < now()`, any user could harvest a new
-- trial every 3 days simply by re-authenticating → unlimited trials per
-- apple_id / google_id.
--
-- Fix (industry-standard, mirrors Apple's isEligibleForIntroOffer which is a
-- permanent per-Apple-ID flag that only ever goes eligible→ineligible): add a
-- per-identity `trial_granted_at` stamp. The trial is granted at most once;
-- the grant path now checks this column, NOT subscription_expiry (which an
-- admin/support action can legitimately clear).
--
-- Idempotent: this whole file re-runs on every deploy (deploy.sh applies all
-- migrations/0NN_*.sql), so use IF NOT EXISTS + a NULL-guarded backfill.

BEGIN;

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS trial_granted_at TIMESTAMPTZ;

-- Backfill: every pre-existing user has already been through createUser (which
-- granted a trial) or otherwise has subscription history, so mark them all as
-- already-granted using their creation time. This guarantees no existing
-- account can claim a fresh trial after this ships. Only touches rows still
-- NULL, so re-running the migration is a no-op (and admin-cleared rows that we
-- intentionally re-stamp would only ever be set once here).
UPDATE users
    SET trial_granted_at = created_at
    WHERE trial_granted_at IS NULL;

COMMIT;
