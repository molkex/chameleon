-- 005_device_info.sql
-- Track per-user device / client / location info, updated each time a user
-- fetches their VPN config via /api/mobile/config.
--
-- All fields are optional and populated best-effort: UA parsing happens
-- inline, GeoIP lookups happen in a background goroutine and may lag the
-- first request for a given IP.

ALTER TABLE users ADD COLUMN IF NOT EXISTS last_seen         TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_ip           VARCHAR(64)  DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_user_agent   TEXT         DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS app_version       VARCHAR(32)  DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS os_name           VARCHAR(32)  DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS os_version        VARCHAR(32)  DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_country      VARCHAR(8)   DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_country_name VARCHAR(128) DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_city         VARCHAR(128) DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_users_last_seen ON users (last_seen DESC) WHERE last_seen IS NOT NULL;
