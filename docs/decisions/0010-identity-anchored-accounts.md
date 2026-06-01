---
title: Identity-anchored accounts (not device-anchored)
date: 2026-06-01
status: accepted
tags: [accounts, identity, payments, acct-identity, ios]
supersedes: none
related: incidents/2026-06-01-acct-identity-demote.md, incidents/2026-06-01-acct-identity-demote-recurrence.md
---

# 0010 — Identity-anchored accounts

## Context

Two ACCT-IDENTITY P0s (2026-06-01) demoted paying users to fresh anonymous trials.
Root pattern: **the account is anchored to the device** (`device_id` in Keychain +
an anonymous `device_*` user row). When the client loses that local state — a Keychain
wipe, a bad cached config, an onboarding-flag misread — it re-registers anonymously,
minting a NEW account + a FRESH 3-day trial. This simultaneously (a) orphans the payer
and (b) hands out unlimited free trials.

A 2026-06-01 industry review (RevenueCat, Apple StoreKit, Mullvad) confirmed this is the
textbook **anonymous-ID anti-pattern**:
- RevenueCat: anonymous IDs are device-cached; delete/reinstall (or any cache reset)
  → new anonymous ID → **lost entitlements**. Their #1 rule: if you have your own
  accounts, anchor to a stable custom App User ID; anonymous is a pre-login state only.
- Apple: trial-abuse resistance comes from `isEligibleForIntroOffer`, keyed to the
  **Apple ID** (store account) which survives reinstall. Non-renewing subs + consumables
  are NOT on the store receipt → can't be restored from it (our IAPs are non-renewing →
  need server-side binding via `appAccountToken`).
- Mullvad (privacy-VPN canonical): a random **account number** the user holds is the
  sole, durable, PII-free credential; restore = re-enter the number.

## Decision

**The durable account anchor is an IDENTITY, not the device.** Priority of anchors:
1. **Apple / Google** sign-in (reclaim by `sub`).
2. **Email** (magic-link) — already captured at FreeKassa payment (`SetUserEmail`); RU
   payers therefore already have a recoverable anchor.
3. **`appAccountToken`** for Apple IAP (binds a non-renewing transaction to our user
   server-side — finishes BE-01a).
The anonymous `device_*` account is a legitimate **first-run / pre-login** state only;
it must never be the home of a paid subscription without an identity attached.

Concrete invariants:
- **Never wipe identity on a transient/data problem** (bad config, network, flag) — only
  on explicit sign-out. (Enforced: `shouldAnonReRegister` gate + `isUsableConfigPayload`
  guard; see the two incidents.)
- **Trial eligibility is per identity, not per device row.** Today `trial_granted_at`
  gates per row → a new anon row = new trial. Long-term: gate the trial on the identity
  (Apple `isEligibleForIntroOffer` / email), with device/IP fingerprint only as a
  supplementary fraud signal (NOT the primary gate — that was the "improvisation" the
  industry treats as a last resort).
- **Silent recovery first, gesture only if unavoidable.** On launch, if we're on an
  anonymous account but StoreKit has a live entitlement, reclaim it silently (no prompt)
  even if a trial looks active. Only FreeKassa/identity payers on an already-demoted
  device need one explicit re-auth (security: a stranger device must prove identity
  before claiming a sub).
- **Surface the recovery path** ("returning customer — restore by email / Sign in with
  Apple"), Mullvad/RevenueCat style.

## Consequences

- Build 99 ships the prevention (don't wipe identity) + silent StoreKit reclaim on anon.
- Recovery for already-demoted users: Apple-IAP → silent; FreeKassa/identity → one
  re-auth (by design). Server already reclaims by `apple_id`/`email` on re-auth.
- Follow-ups: finish `appAccountToken` (BE-01a iOS half); make trial eligibility
  identity-keyed; expose a visible "restore by email" entry point; consider a
  user-visible account key (Mullvad-style) for the privacy-anon segment.
- Heuristic device/IP trial-gating is explicitly demoted to a supplementary anti-fraud
  signal, not a primary mechanism.
