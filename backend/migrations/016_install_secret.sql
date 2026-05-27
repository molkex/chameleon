-- 016_install_secret.sql
-- MED-012 Phase 1 (2026-05-27): server-issued install_secret to replace
-- device_id-as-bearer authentication.
--
-- Background: device_id (an iOS identifierForVendor UUID) was both the
-- identity AND the credential for register/refresh flows. Anyone who
-- learned a victim's device_id could re-register and hijack the account.
--
-- This migration adds a server-issued install_secret column. The Register
-- handler generates one on the first register call for a given device_id,
-- stores it, and returns it in the AuthResponse. Subsequent registers
-- that send a matching install_secret are accepted; mismatching ones are
-- rejected.
--
-- Phase 1 (this migration): backward-compatible. iOS clients that don't
-- send install_secret at all are still accepted — needed for legacy
-- builds 75-89 already in the field. Once iOS adoption of the new field
-- crosses ~95%, Phase 2 will flip the gate to strict-require.

BEGIN;

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS install_secret VARCHAR(64);

-- Lookups are always by user id (already PK'd) or by device_id (already
-- indexed). install_secret is only ever compared after the user row has
-- been loaded — no separate index needed.

COMMIT;
