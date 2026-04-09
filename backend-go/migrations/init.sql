-- Chameleon VPN — Database schema
-- Idempotent: safe to run on existing database (all IF NOT EXISTS).

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Users table
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    telegram_id BIGINT,
    username VARCHAR(255),
    full_name VARCHAR(255),
    is_active BOOLEAN DEFAULT true,
    subscription_expiry TIMESTAMPTZ,
    vpn_username VARCHAR(255),
    vpn_uuid VARCHAR(36),
    vpn_short_id VARCHAR(16),
    auth_provider VARCHAR(50),
    apple_id VARCHAR(255),
    device_id VARCHAR(255),
    original_transaction_id VARCHAR(255),
    app_store_product_id VARCHAR(255),
    ad_source VARCHAR(100),
    cumulative_traffic BIGINT DEFAULT 0,
    device_limit INTEGER,
    bot_blocked_at TIMESTAMPTZ,
    phone_number VARCHAR(50),
    google_id VARCHAR(255),
    notified_3d BOOLEAN,
    notified_1d BOOLEAN,
    current_plan VARCHAR(100),
    subscription_token VARCHAR(255),
    activation_code VARCHAR(100),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Auto-update trigger for users.updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

DROP TRIGGER IF EXISTS trg_users_updated_at ON users;
CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Admin users
CREATE TABLE IF NOT EXISTS admin_users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(255) UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    role VARCHAR(50) NOT NULL DEFAULT 'admin',
    is_active BOOLEAN DEFAULT true,
    last_login TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Traffic snapshots
CREATE TABLE IF NOT EXISTS traffic_snapshots (
    id SERIAL PRIMARY KEY,
    vpn_username VARCHAR(255),
    used_traffic BIGINT DEFAULT 0,
    download_traffic BIGINT DEFAULT 0,
    upload_traffic BIGINT DEFAULT 0,
    timestamp TIMESTAMPTZ DEFAULT NOW()
);

-- VPN servers
CREATE TABLE IF NOT EXISTS vpn_servers (
    id SERIAL PRIMARY KEY,
    key VARCHAR(50) UNIQUE NOT NULL,
    name VARCHAR(255) NOT NULL,
    flag VARCHAR(10) DEFAULT '',
    host VARCHAR(255) NOT NULL,
    port INTEGER NOT NULL DEFAULT 2096,
    domain VARCHAR(255) DEFAULT '',
    sni VARCHAR(255) DEFAULT '',
    is_active BOOLEAN DEFAULT true,
    sort_order INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- App settings (key-value store)
CREATE TABLE IF NOT EXISTS app_settings (
    key VARCHAR(255) PRIMARY KEY,
    value TEXT NOT NULL DEFAULT '',
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Node metrics history
CREATE TABLE IF NOT EXISTS node_metrics_history (
    id SERIAL PRIMARY KEY,
    node_key VARCHAR(50),
    cpu REAL,
    ram_used REAL,
    ram_total REAL,
    disk REAL,
    traffic_up BIGINT DEFAULT 0,
    traffic_down BIGINT DEFAULT 0,
    online_users INTEGER,
    recorded_at TIMESTAMPTZ DEFAULT NOW()
);

-- Cluster peers
CREATE TABLE IF NOT EXISTS cluster_peers (
    id SERIAL PRIMARY KEY,
    node_id VARCHAR(100) UNIQUE NOT NULL,
    url TEXT NOT NULL,
    ip VARCHAR(45),
    last_sync TIMESTAMPTZ,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Admin audit log
CREATE TABLE IF NOT EXISTS admin_audit_log (
    id SERIAL PRIMARY KEY,
    admin_user_id INTEGER REFERENCES admin_users(id),
    action VARCHAR(255) NOT NULL,
    ip VARCHAR(45),
    user_agent TEXT,
    details TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_vpn_username ON users (vpn_username) WHERE vpn_username IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_vpn_uuid ON users (vpn_uuid);
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_sub_token ON users (subscription_token) WHERE subscription_token IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_activation_code ON users (activation_code) WHERE activation_code IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_original_txn_id ON users (original_transaction_id) WHERE original_transaction_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_users_apple_id ON users (apple_id) WHERE apple_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_users_device_id ON users (device_id) WHERE device_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_users_active_expiry ON users (is_active, subscription_expiry);
CREATE INDEX IF NOT EXISTS idx_users_auth_provider ON users (auth_provider) WHERE auth_provider IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_traffic_snap_user_ts ON traffic_snapshots (vpn_username, timestamp);
CREATE INDEX IF NOT EXISTS idx_traffic_ts ON traffic_snapshots (timestamp);
CREATE INDEX IF NOT EXISTS idx_audit_log_created ON admin_audit_log (created_at);
CREATE INDEX IF NOT EXISTS idx_node_metrics_time ON node_metrics_history (node_key, recorded_at);

-- Add reality_public_key column (each node has its own Reality key pair).
ALTER TABLE vpn_servers ADD COLUMN IF NOT EXISTS reality_public_key VARCHAR(255) DEFAULT '';

-- Seed default VPN servers (skip if already exist)
INSERT INTO vpn_servers (key, name, flag, host, port, domain, sni, is_active, sort_order) VALUES
    ('de', 'Germany', '🇩🇪', '162.19.242.30', 2096, '', 'ads.adfox.ru', true, 1),
    ('nl', 'Netherlands', '🇳🇱', '194.135.38.90', 2096, '', 'ads.adfox.ru', true, 2),
    ('relay-de', 'Russia → DE', '🇷🇺', '185.218.0.43', 443, '', 'ads.adfox.ru', true, 3),
    ('relay-nl', 'Russia → NL', '🇷🇺', '185.218.0.43', 2098, '', 'ads.adfox.ru', true, 4)
ON CONFLICT (key) DO NOTHING;

-- Provider info columns for vpn_servers (hosting provider, cost, credentials, notes).
ALTER TABLE vpn_servers ADD COLUMN IF NOT EXISTS provider_name VARCHAR(255) DEFAULT '';
ALTER TABLE vpn_servers ADD COLUMN IF NOT EXISTS cost_monthly DECIMAL(10,2) DEFAULT 0;
ALTER TABLE vpn_servers ADD COLUMN IF NOT EXISTS provider_url VARCHAR(500) DEFAULT '';
ALTER TABLE vpn_servers ADD COLUMN IF NOT EXISTS provider_login VARCHAR(255) DEFAULT '';
ALTER TABLE vpn_servers ADD COLUMN IF NOT EXISTS provider_password VARCHAR(255) DEFAULT '';
ALTER TABLE vpn_servers ADD COLUMN IF NOT EXISTS notes TEXT DEFAULT '';
