-- Whitelist-bypass category for legacy SPB relay rows.
--
-- Problem (post-010): the SPB relay rows (`relay-de`, `relay-nl`) live as
-- role='exit' because they terminate the client connection, but from a UX
-- standpoint they're a narrow, RU-whitelist-only option — not a primary
-- egress. Mixing them into country-exit groups (under 🇩🇪 / 🇳🇱) would
-- confuse users; hiding them entirely breaks the whitelist-bypass feature.
--
-- Solution: introduce a `category` enum that lets the client config
-- generator (and the iOS picker) render whitelist-bypass servers as a
-- dedicated "🇷🇺 Россия (обход белых списков)" group, separate from
-- regular country groups and excluded from the "Auto" global urltest.
--
-- See memory/project_relay_architecture_poc.md and docs/ROADMAP.md.

ALTER TABLE vpn_servers
    ADD COLUMN IF NOT EXISTS category TEXT NOT NULL DEFAULT 'standard'
    CHECK (category IN ('standard', 'whitelist_bypass'));

-- Backfill: legacy SPB relays are whitelist-bypass.
-- Their country_code stays NULL — they don't fit the country-exit model
-- (entry=RU, exit=foreign), they live in their own dedicated group.
UPDATE vpn_servers
SET category = 'whitelist_bypass', updated_at = NOW()
WHERE key IN ('relay-de', 'relay-nl')
  AND category != 'whitelist_bypass';
