-- Add updated_at column to users table with trigger for automatic updates.
-- Add cluster_peers table for mesh synchronization.

ALTER TABLE users ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP DEFAULT NOW();

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'trg_users_updated_at'
    ) THEN
        CREATE TRIGGER trg_users_updated_at
            BEFORE UPDATE ON users
            FOR EACH ROW
            EXECUTE FUNCTION update_updated_at();
    END IF;
END
$$;

-- Backfill existing rows
UPDATE users SET updated_at = COALESCE(created_at, NOW()) WHERE updated_at IS NULL;

-- Cluster peers table
CREATE TABLE IF NOT EXISTS cluster_peers (
    id SERIAL PRIMARY KEY,
    node_id VARCHAR(64) NOT NULL UNIQUE,
    url VARCHAR(512) NOT NULL,
    ip VARCHAR(45),
    last_sync TIMESTAMP DEFAULT NOW(),
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT NOW()
);
