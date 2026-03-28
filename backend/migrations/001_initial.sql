-- Initial schema matching existing Python/Alembic database.
-- This migration is idempotent (CREATE TABLE IF NOT EXISTS).

CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    telegram_id BIGINT,
    username VARCHAR(255),
    full_name VARCHAR(255),
    is_active BOOLEAN NOT NULL DEFAULT true,
    subscription_expiry TIMESTAMP,
    vpn_username VARCHAR(255),
    vpn_uuid VARCHAR(255),
    vpn_short_id VARCHAR(32),
    auth_provider VARCHAR(32),
    apple_id VARCHAR(255),
    device_id VARCHAR(255),
    original_transaction_id VARCHAR(255),
    app_store_product_id VARCHAR(255),
    ad_source VARCHAR(128),
    cumulative_traffic BIGINT DEFAULT 0,
    device_limit INTEGER,
    bot_blocked_at TIMESTAMP,
    phone_number VARCHAR(64),
    google_id VARCHAR(255),
    notified_3d BOOLEAN DEFAULT false,
    notified_1d BOOLEAN DEFAULT false,
    current_plan VARCHAR(64),
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS transactions (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    amount NUMERIC(12, 2),
    currency VARCHAR(16),
    provider_payment_charge_id VARCHAR(255),
    status VARCHAR(32) DEFAULT 'pending',
    description TEXT,
    plan VARCHAR(64),
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS proxy_stats (
    id SERIAL PRIMARY KEY,
    date DATE UNIQUE,
    unique_clicks INTEGER DEFAULT 0,
    total_clicks INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS proxy_clicks (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    clicked_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS traffic_snapshots (
    id SERIAL PRIMARY KEY,
    vpn_username VARCHAR(255),
    used_traffic BIGINT DEFAULT 0,
    download_traffic BIGINT DEFAULT 0,
    upload_traffic BIGINT DEFAULT 0,
    timestamp TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_traffic_snap_user_ts ON traffic_snapshots(vpn_username, timestamp);

CREATE TABLE IF NOT EXISTS monitor_checks (
    id SERIAL PRIMARY KEY,
    resource VARCHAR(255),
    url TEXT,
    category VARCHAR(64),
    via_vpn BOOLEAN DEFAULT false,
    is_available BOOLEAN DEFAULT false,
    is_throttled BOOLEAN DEFAULT false,
    is_geo_blocked BOOLEAN DEFAULT false,
    response_time_ms FLOAT,
    download_speed_kbps FLOAT,
    dns_resolved BOOLEAN,
    exit_ip VARCHAR(64),
    http_status INTEGER,
    error_message TEXT,
    protocol VARCHAR(64),
    checked_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS analytics_events (
    id SERIAL PRIMARY KEY,
    user_id INTEGER,
    event_type VARCHAR(64),
    event_data JSONB,
    timestamp TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS domain_stats (
    id SERIAL PRIMARY KEY,
    date DATE,
    domain VARCHAR(255),
    category VARCHAR(64),
    hit_count INTEGER DEFAULT 0,
    unique_users INTEGER DEFAULT 0,
    users_list JSONB
);

CREATE TABLE IF NOT EXISTS ad_campaigns (
    id SERIAL PRIMARY KEY,
    slug VARCHAR(128) UNIQUE NOT NULL,
    name VARCHAR(255),
    channel VARCHAR(255),
    budget_rub NUMERIC(12, 2),
    notes TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS vpn_test_results (
    id SERIAL PRIMARY KEY,
    username VARCHAR(255),
    client_ip VARCHAR(64),
    isp VARCHAR(255),
    asn VARCHAR(32),
    country VARCHAR(8),
    city VARCHAR(128),
    vpn_detected BOOLEAN,
    overall_score FLOAT,
    connectivity_score FLOAT,
    speed_score FLOAT,
    security_score FLOAT,
    download_mbps FLOAT,
    upload_mbps FLOAT,
    ping_ms FLOAT,
    platform VARCHAR(64),
    browser VARCHAR(128),
    connection_type VARCHAR(64),
    configs_working INTEGER,
    configs_total INTEGER,
    best_config_name VARCHAR(128),
    best_config_download FLOAT,
    best_config_upload FLOAT,
    best_config_ping FLOAT,
    xhttp_available BOOLEAN,
    grpc_available BOOLEAN,
    hy2_available BOOLEAN,
    issues_json JSONB,
    results_json JSONB,
    tested_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS admin_users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(64) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(32) NOT NULL DEFAULT 'viewer',
    is_active BOOLEAN NOT NULL DEFAULT true,
    last_login TIMESTAMP,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS admin_audit_log (
    id SERIAL PRIMARY KEY,
    admin_user_id INTEGER REFERENCES admin_users(id),
    action VARCHAR(64) NOT NULL,
    ip VARCHAR(64) NOT NULL,
    user_agent VARCHAR(256),
    details VARCHAR(512),
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS support_messages (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id),
    direction VARCHAR(16) NOT NULL,
    content TEXT NOT NULL,
    attachments JSONB,
    is_read BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_support_user_ts ON support_messages(user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_support_unread ON support_messages(direction, is_read);
