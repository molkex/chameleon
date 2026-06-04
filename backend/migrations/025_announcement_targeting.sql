-- 025_announcement_targeting.sql
-- Audience targeting for in-app announcements (INAPP-ANNOUNCEMENTS follow-up).
-- Two independent filters, ANDed at fetch time against the requesting user:
--   audience: all | trial | paid | expired   (subscription state)
--   platform: all | ios  | macos             (last-seen OS)
-- 'all' on both = unchanged behaviour (everyone).
ALTER TABLE announcements
    ADD COLUMN IF NOT EXISTS audience VARCHAR(16) NOT NULL DEFAULT 'all'
        CHECK (audience IN ('all', 'trial', 'paid', 'expired')),
    ADD COLUMN IF NOT EXISTS platform VARCHAR(16) NOT NULL DEFAULT 'all'
        CHECK (platform IN ('all', 'ios', 'macos'));
