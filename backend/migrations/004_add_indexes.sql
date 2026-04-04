-- Performance indexes for users table lookups.
-- Critical for scaling beyond 10K users.

CREATE INDEX IF NOT EXISTS idx_users_vpn_username ON users(vpn_username);
CREATE INDEX IF NOT EXISTS idx_users_apple_id ON users(apple_id) WHERE apple_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_users_device_id ON users(device_id) WHERE device_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_users_active_expiry ON users(is_active, subscription_expiry);
CREATE INDEX IF NOT EXISTS idx_users_auth_provider ON users(auth_provider) WHERE auth_provider IS NOT NULL;

-- Audit log performance
CREATE INDEX IF NOT EXISTS idx_audit_log_created ON admin_audit_log(created_at);

-- Traffic snapshots — for future partitioning
CREATE INDEX IF NOT EXISTS idx_traffic_ts ON traffic_snapshots(timestamp);
