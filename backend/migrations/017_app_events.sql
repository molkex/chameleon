-- 017_app_events.sql
-- USR-09 Phase 2 (2026-05-28): client-side event collection table.
--
-- Background: the funnel page added in USR-09 Phase 1 derives everything
-- it shows from the existing `users` and `payments` tables (signups,
-- DAU, conversion %, retention cohorts). That covers the post-signup
-- side of the funnel. What it cannot answer is the *pre-purchase* side:
-- how many users opened the paywall, which product they tapped,
-- whether they cancelled or saw an error, how many VPN connection
-- attempts failed silently.
--
-- This table is the destination for iOS-side telemetry batches posted
-- to POST /api/v1/events/batch. Schema is deliberately permissive:
-- event_name is a free string, properties is JSONB, so iOS can evolve
-- the event vocabulary independently of the schema. The server
-- enriches each row with request-time fields (ip, country, received_at)
-- that the client cannot be trusted to set.
--
-- Retention is open-ended on day one. A scheduled DELETE for events
-- older than ~90 days can be added later if the table grows.

BEGIN;

CREATE TABLE IF NOT EXISTS app_events (
    id            BIGSERIAL PRIMARY KEY,

    -- Identity. user_id is the authenticated identity from the JWT;
    -- device_id mirrors the client-supplied X-Device-Model-ish field
    -- so we can correlate pre-signup events later (Phase 3) if iOS
    -- ever sends them anonymously.
    user_id       BIGINT REFERENCES users(id) ON DELETE CASCADE,
    device_id     TEXT,

    -- Free-form. Convention: "subject.verb" lowercase dotted form,
    -- e.g. "paywall.view", "purchase.cancel", "vpn.connect.fail".
    event_name    TEXT NOT NULL,
    properties    JSONB NOT NULL DEFAULT '{}'::jsonb,

    -- Build context — populated from request headers / claims when
    -- present. Used to slice events by build (post-release smoke vs
    -- legacy field installs).
    app_version   TEXT,
    platform      TEXT,   -- 'ios' / 'macos' / future

    -- Clocks. occurred_at is what the client said happened; received_at
    -- is when we wrote the row. A large delta means batched/replayed
    -- events from a previously-offline client.
    occurred_at   TIMESTAMPTZ NOT NULL,
    received_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Network context — server-only, so a malicious client cannot
    -- spoof country to skew the funnel.
    ip            TEXT,
    country       TEXT
);

-- Hot path 1: user detail page wants the full event history for one
-- user, newest first.
CREATE INDEX IF NOT EXISTS idx_app_events_user_occurred
    ON app_events (user_id, occurred_at DESC)
    WHERE user_id IS NOT NULL;

-- Hot path 2: aggregate "events of type X over the last N days" for
-- the funnel/timeseries widget.
CREATE INDEX IF NOT EXISTS idx_app_events_name_occurred
    ON app_events (event_name, occurred_at DESC);

-- Hot path 3: generic recent feed (admin events list) regardless of
-- name. Sequential scan with this index avoids a sort on large windows.
CREATE INDEX IF NOT EXISTS idx_app_events_occurred
    ON app_events (occurred_at DESC);

COMMIT;
