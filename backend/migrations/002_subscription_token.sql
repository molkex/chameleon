-- Add cryptographic subscription token to replace guessable vpn_username in /sub/{token}
CREATE EXTENSION IF NOT EXISTS pgcrypto;

ALTER TABLE users ADD COLUMN IF NOT EXISTS subscription_token VARCHAR(64);

-- Generate tokens for existing users
UPDATE users SET subscription_token = encode(gen_random_bytes(24), 'hex')
WHERE subscription_token IS NULL AND vpn_uuid IS NOT NULL;

-- Create unique index
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_sub_token ON users(subscription_token) WHERE subscription_token IS NOT NULL;
