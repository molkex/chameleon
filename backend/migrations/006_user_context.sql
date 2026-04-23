-- 006_user_context.sql
-- Expand user tracking with signup-time location (captured BEFORE first VPN
-- connect, so it reflects the user's real country) and client-reported
-- metadata from iOS headers (timezone, device model, precise iOS version,
-- preferred language, install date, App Store country).
--
-- Privacy / Apple compliance:
--   * initial_* is populated once at /auth/register via GeoIP lookup.
--     Subsequent GeoIP calls from /mobile/config are removed — we rely on
--     last_ip + is_via_vpn detection in the admin layer instead.
--   * timezone / device_model / ios_version / accept_language come from
--     HTTP headers the app already emits (standard browser-equivalent
--     telemetry), no new sensors, no user permission required.

ALTER TABLE users ADD COLUMN IF NOT EXISTS initial_ip           VARCHAR(64)  DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS initial_country      VARCHAR(8)   DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS initial_country_name VARCHAR(128) DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS initial_city         VARCHAR(128) DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS timezone             VARCHAR(64)  DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS device_model         VARCHAR(64)  DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS ios_version          VARCHAR(32)  DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS accept_language      VARCHAR(128) DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS install_date         DATE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS store_country        VARCHAR(8)   DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_users_initial_country ON users (initial_country) WHERE initial_country <> '';
