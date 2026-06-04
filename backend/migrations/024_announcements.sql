-- 024_announcements.sql
-- In-app announcements (INAPP-ANNOUNCEMENTS): an admin-authored message the
-- client fetches on app open and shows as a dismissible card. Distinct from
-- push — reaches every active user (no notification permission needed) and is
-- fully backend-controlled after the client ships once.
CREATE TABLE IF NOT EXISTS announcements (
    id          BIGSERIAL PRIMARY KEY,
    title       TEXT NOT NULL,
    body        TEXT NOT NULL,
    kind        VARCHAR(16) NOT NULL DEFAULT 'info'
                    CHECK (kind IN ('info', 'promo', 'update')),
    active      BOOLEAN NOT NULL DEFAULT TRUE,
    starts_at   TIMESTAMPTZ,                 -- optional show-window start (NULL = immediately)
    ends_at     TIMESTAMPTZ,                 -- optional show-window end   (NULL = forever)
    cta_label   TEXT,                        -- optional button label
    cta_url     TEXT,                        -- optional button URL (opens in browser)
    created_by  TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- The client's hot path = "active announcements in window", so index active rows.
CREATE INDEX IF NOT EXISTS idx_announcements_active
    ON announcements (active, id DESC) WHERE active;
