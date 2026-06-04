-- 021_support_attachments.sql
-- SUPPORT-CHAT attachments (ADR 0011 follow-up): file/photo uploads.
--
-- A message can carry at most one attachment. The bytes live in Backblaze B2
-- (S3-compatible) under the support/ prefix; the DB only stores the object key
-- plus declared metadata. The client uploads directly via a presigned PUT URL
-- and the message row references it by key — the backend never proxies bytes.
--
-- Columns are nullable: a plain text message leaves them NULL. attachment_size
-- is the declared size in bytes (validated <=10 MiB at the API layer before a
-- presigned URL is issued).
--
-- These columns are on the repo-managed support_chat_messages table (migration
-- 020), so the IF NOT EXISTS guards are pure idempotency, not a collision dodge.
--
-- Idempotent: re-runs on every deploy.

ALTER TABLE support_chat_messages
    ADD COLUMN IF NOT EXISTS attachment_key  TEXT,
    ADD COLUMN IF NOT EXISTS attachment_mime TEXT,
    ADD COLUMN IF NOT EXISTS attachment_name TEXT,
    ADD COLUMN IF NOT EXISTS attachment_size BIGINT;
