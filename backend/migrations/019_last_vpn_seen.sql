-- 019_last_vpn_seen.sql
-- METRICS (2026-06-03): make the admin "Active (24h/30d)" honest.
--
-- Problem: the dashboard "Active (24h)" counted users by `last_seen`, which is
-- ONLY bumped when the iOS app calls GET /api/v1/mobile/config (touchDevice).
-- A VPN is "connect once, leave it on": the tunnel carries traffic for days
-- without re-fetching /config, so an actively-tunnelling user falls out of the
-- 24h window. Result: "Online: 35" (live sing-box sessions) could exceed
-- "Active (24h): 16" (app opens) — looks self-contradictory.
--
-- Fix: a separate `last_vpn_seen` stamp meaning "actually moved VPN traffic",
-- bumped by the traffic collector (main.go runTrafficCollector) for every user
-- with a non-zero traffic delta in the interval. The dashboard counts active =
-- last_seen OR last_vpn_seen within the window. `last_seen` is deliberately
-- LEFT ALONE so DAU / retention / funnel (db/funnel.go, metrics RefreshDAU)
-- keep meaning "app engagement", not VPN usage.
--
-- Node scope: traffic stats come from NL's sing-box (relays forward to NL, so
-- RU users are covered). GRA-direct (fr-direct-gra1) users transit GRA's own
-- sing-box and are not yet captured — same known gap as TRAFFIC-MULTIEXIT.
--
-- Idempotent: re-runs on every deploy. No backfill — the column populates
-- naturally as traffic flows.

BEGIN;

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS last_vpn_seen TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_users_last_vpn_seen
    ON users (last_vpn_seen)
    WHERE last_vpn_seen IS NOT NULL;

COMMIT;
