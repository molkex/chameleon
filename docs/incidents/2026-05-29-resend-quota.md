---
date: 2026-05-29
severity: medium
component: backend/email (Resend)
status: resolved
---

# Resend daily quota exhausted (100 emails/day) — blocked auth emails

## Symptom

Resend dashboard showed **100% of the 100 emails/day free quota** consumed for
team `molkex` ("Daily Quota Limit" screen, "Upgrade Now" CTA). Once over quota,
Resend stops sending — which would break magic-link sign-in/sign-up for real
users.

## Investigation

Queried `magic_tokens` on NL prod. Last 24h: **121 tokens issued, 119 unique
emails, but only 5 distinct real IPs** — 114 rows had a NULL `created_ip`,
meaning they were server-issued, not user-initiated from the app.

Breakdown by `purpose` (last 24h):

| purpose         | count | note |
|-----------------|-------|------|
| `apple_backup`  | 107   | auto-sent after Apple Sign-In |
| `google_backup` | 7     | auto-sent after Google Sign-In |
| `email_signup`  | 7     | real user sign-ups |

64 of the recipient addresses were `@privaterelay.appleid.com` (Apple
Hide-My-Email) — addresses the user almost never checks.

**Decisive metric** — usage of issued links across all time:

| purpose         | issued | used | used % |
|-----------------|--------|------|--------|
| `apple_backup`  | 183    | 0    | 0%     |
| `google_backup` | 21     | 0    | 0%     |
| `email_signup`  | 15     | 5    | 33%    |
| `email_login`   | 8      | 5    | 62%    |

## Root cause

After every **first** Apple/Google social sign-in, the backend fire-and-forget
mailed a "backup magic link" so the user would have an email fallback if they
lost their social account (`issueBackupMagicLink`, called from `auth.go` and
`auth_google.go`). The feature was well-intentioned but:

- **0 of 204** backup links were ever used.
- It consumed **~84%** of the Resend daily quota.
- The majority went to Apple relay addresses the user never opens.

So the quota was exhausted by a feature with zero demonstrated value, not by
real auth traffic (which is ~15–20 emails/day and fits the free tier ~5×).

## Why we didn't self-host SMTP instead

Considered and rejected (still valid): a fresh-domain VPS SMTP almost certainly
lands in Junk on iCloud/Gmail (83% of our recipients are Apple+Gmail). The code
comment in `auth_magic.go` already records that even branded HTML hit Junk on
fresh-domain iCloud; deliverability is driven by warmed IP-pool reputation,
which Resend provides and a single 2GB NL node (already running
backend+VPN+pg+redis) cannot. Resend remains correct for *transactional auth*.

## Fix

Removed the auto backup-magic-link entirely (both Apple and Google paths):

- `backend/internal/api/mobile/auth.go` — dropped `apple_backup` send.
- `backend/internal/api/mobile/auth_google.go` — dropped `google_backup` send
  and deleted the now-orphaned `issueBackupMagicLink` helper.

Expected new load: ~15–20 emails/day → comfortably inside the free 100/day tier.
**No payment needed.** `go build` / `go vet` / `go test ./internal/api/mobile/`
all green.

## Follow-up (optional, not done)

If an email fallback for social-login users is ever wanted, make it **opt-in**:
an explicit "set up email sign-in" action in-app, never auto-fired on signup,
and skip `@privaterelay.appleid.com` recipients.
