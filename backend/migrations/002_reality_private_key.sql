-- Add reality_private_key column to vpn_servers.
-- Each node stores its own Reality key pair in the database (single source of truth).
-- Private key is used server-side only for singbox config generation.
ALTER TABLE vpn_servers ADD COLUMN IF NOT EXISTS reality_private_key VARCHAR(255) DEFAULT '';
