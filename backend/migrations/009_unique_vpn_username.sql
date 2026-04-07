-- Add UNIQUE constraint on vpn_username for cluster sync ON CONFLICT to work.
-- PostgreSQL requires a non-partial unique index for ON CONFLICT (column) syntax.
-- NULLs are treated as distinct, so multiple NULL vpn_username rows are allowed.

-- First, deduplicate any existing duplicates (keep the newest row)
DELETE FROM users a USING users b
WHERE a.vpn_username IS NOT NULL
  AND a.vpn_username = b.vpn_username
  AND a.id < b.id;

-- Drop the old non-unique index
DROP INDEX IF EXISTS idx_users_vpn_username;

-- Create unique index (full, not partial — required for ON CONFLICT)
CREATE UNIQUE INDEX idx_users_vpn_username ON users(vpn_username);
