-- 004_ui_theme.sql — user UI theme preference (for analytics + sync across devices)
ALTER TABLE users ADD COLUMN IF NOT EXISTS ui_theme TEXT NOT NULL DEFAULT 'calm';
