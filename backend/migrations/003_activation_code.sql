-- Separate activation_code from subscription_token.
-- subscription_token is public (in sub links), activation_code is secret (for login).
CREATE EXTENSION IF NOT EXISTS pgcrypto;

ALTER TABLE users ADD COLUMN IF NOT EXISTS activation_code VARCHAR(64);

-- Generate activation codes for existing users that have subscription tokens
UPDATE users SET activation_code = encode(gen_random_bytes(24), 'hex')
WHERE activation_code IS NULL AND vpn_uuid IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_users_activation_code
ON users(activation_code) WHERE activation_code IS NOT NULL;
