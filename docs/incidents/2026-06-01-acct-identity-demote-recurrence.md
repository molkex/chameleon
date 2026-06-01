---
title: ACCT-IDENTITY demote recurred on build 98 (bad cached config wiped a payer)
date: 2026-06-01
status: fixed
tags: [acct-identity, ios, p0, regression, payments]
supersedes: none
related: 2026-06-01-acct-identity-demote.md
---

# ACCT-IDENTITY demote — recurrence on build 98

## Symptom

User: "при подключении к ВПН сменился акк на 0668c8cb." On an iPhone 16 Pro running
TestFlight build 98 (1.0.29), a paying Apple account was replaced by a fresh
anonymous trial account on VPN connect.

## Evidence (NL Postgres, same physical device `iPhone17,1`)

```
id 12351  device_b6f01ebb  auth=apple  sub→2026-06-15 (PAID)  UA MadFrogVPN/98  last_seen 16:57:59
id 159280 device_0668c8cb  auth=device (ANON)  fresh 3-day trial  UA MadFrogVPN/98  created 16:58:00
```

A paying Apple user was demoted to a fresh anon trial **one second later**, on a build
that **already contained** the first ACCT-IDENTITY fix (commit `71c10b2`, 01:12, shipped
in builds 93–98). So the fix was **incomplete** — a second demote path survived.

The original fix (incident 2026-06-01-acct-identity-demote.md) hardened the *runtime*
session paths: `fetchAndSaveConfig` 401/404 handling + the `initialize` onboarding-flag.
It did NOT touch a separate, older demote trigger.

## Root cause (two unguarded bugs in series)

1. **`doFetchAndSave` / `saveConfig` cached ANY response** — no validation. On RU LTE the
   direct-IP / Cloudflare fallback can return a non-config body (CF/relay HTML error page,
   throttled/empty response, or a backend error JSON returned 200). That body got written
   as the cached `/config`.
2. **`initialize()` then `clear()`-ed the WHOLE identity** when the cached body contained
   `"error"` and lacked `"outbounds"` — `authProvider`, `appleUserID`, tokens, device_id —
   with **no `authProvider` guard**. The Apple user dropped to onboarding → "continue
   without account" → a brand-new anon `device_0668c8cb` (different device_id, fresh trial).

The connect-path config fetch (`silentConfigUpdate → fetchAndSaveConfig`) is correctly
guarded for identity users, so the wipe was launch-time, after a bad config got cached.

## Fix

Pure helper `AppState.isUsableConfigPayload(_:)` (a real sing-box config always has
`"outbounds"`), used at both trip-wires:

- **Guard 1 — never cache a non-config.** `doFetchAndSave` throws a transient
  `networkError` instead of `saveConfig`-ing a payload without `"outbounds"`. The arming
  step is gone; the old cached config is kept.
- **Guard 2 — never wipe identity on a bad config.** `initialize()` now discards ONLY the
  cached config file + start-options on an unusable cache and re-fetches for the SAME
  identity. It NEVER calls `configStore.clear()` (which is now reserved for explicit
  sign-out / account delete).

Regression tests: `AcctIdentityTests` — `isUsableConfigPayload` accepts a real config,
rejects error JSON / HTML error page / empty / `null`. Build-for-testing green.

Also fixed an adjacent diagnostics bug: `MadFrogVPNApp.swift` logged a hardcoded
`build 38d` on every launch — replaced with the real `CFBundleVersion`, so future logs
report the actual build (this masked the build in the very log that reported this bug).

## Recovery for the affected user

Account 12351 still exists with its sub intact until 2026-06-15. Sign in with Apple again
(or Restore Purchases) on the device — the backend reclaims the same account by Apple `sub`
/ originalTransactionId. No data loss. Ships in build 99 (1.0.29).

## Follow-up

- Backend could also detect & ignore "duplicate fresh anon right after an active payer on
  the same device_model + network" but that's heuristic; the client guards are the fix.
- Audit other `clear()` call sites for the same "transient problem ⇒ identity wipe" smell
  (done: only :493 anon-guarded and :954 explicit sign-out remain — both correct).
