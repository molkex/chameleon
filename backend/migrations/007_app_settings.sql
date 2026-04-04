-- Database-backed application settings (key-value store).
-- Settings here override .env values at runtime.

CREATE TABLE IF NOT EXISTS app_settings (
    key VARCHAR(128) PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT NOW()
);
