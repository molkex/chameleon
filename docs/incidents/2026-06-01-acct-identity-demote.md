---
title: ACCT-IDENTITY — app silently demoted Apple-authed payer to anonymous trial
date: 2026-06-01
status: resolved
tags: [incident, auth, apple, identity, p0]
---
# 2026-06-01 — ACCT-IDENTITY: app silently demoted an Apple-authed payer to a fresh anonymous trial

**Severity:** P0 (paying users lost their account in-app) · **Status:** fixed
(backend deployed 2026-05-31 21:55Z; iOS in the Phase-B build) · **Auth-sensitive.**

## Symptom

A Sign in with Apple user with an active paid subscription (to 2026-06-15) was
silently replaced, in-app, by a brand-new anonymous `device_<rand>` 3-day-trial
account — no re-login, no app update. iPhone showed `device_e9afc143`, iPad
`device_2c537874`; the real account `device_b6f01ebb` (id 12351, `auth_provider=apple`)
was only recoverable by manually re-tapping Sign in with Apple. 7+ device rows
were already orphaned (NULL `device_id`).

## Root cause

The app treated **app-group UserDefaults as more durable than the Keychain** and
**had no concept of an "identity" user**, so any session hiccup fell through to
anonymous `registerDevice()` — minting a fresh trial and overwriting the stored
username. Two triggers:

1. **`AppState.initialize`** — `if !onboardingCompleted && username != nil { configStore.clear() }`.
   The `onboardingCompleted` app-group UD flag does **not** survive a container
   reset; the Keychain creds **do**. Flag-missing + creds-present was misread as
   "fresh install" → wipe → anon register.
2. **`fetchAndSaveConfig`** — on `401`→refresh-fail and on `404 user_not_found`
   the catch path called `reRegisterDevice()` → `registerDevice()` (anonymous),
   never the user's actual provider. No `auth_provider` was persisted, so the app
   couldn't tell an Apple user from a guest.

Backend amplifier **SEC-01**: `AppleSignIn`/`GoogleSignIn` re-granted a fresh
3-day trial on **every** expired-sub sign-in (gate was only `subscription_expiry < now`),
so reclaim handed out new trials and any `apple_id` could harvest unlimited trials.

## Fix (research-backed — Apple docs / RevenueCat / Firebase / Auth0 / RFC 9700 / OWASP)

**iOS (Phase-B build):**
- **Keychain = source of truth.** Persist `auth_provider` + Apple `sub`
  (`appleUserID`) in the Keychain alongside the tokens (`ConfigStore`).
- **Kill trigger 1** — `initialize` never wipes; creds-present ⇒ established
  user, self-heal the `onboardingCompleted` flag.
- **Kill trigger 2** — `fetchAndSaveConfig` gates the anon `registerDevice()`
  fallback on `auth_provider == nil`. An identity user with a dead session keeps
  its creds and surfaces a non-destructive re-auth banner (`needsReauth`).
- **Recovery ladder** (`ReauthView`): launch `getCredentialState(forUserID:)` →
  silent refresh-token → Apple re-auth (reclaim by `sub`) → email magic-link
  (cross-device last resort, reuses `EmailSignInView`). Truly silent Apple token
  minting is impossible (identity token TTL 10 min, needs UI) — confirmed.
- **StoreKit backstop** — on launch, if the backend shows no active sub but
  `Transaction.currentEntitlements` has a live one, push the JWS so the server
  reclaims it (`SubscriptionManager.reconcileEntitlementsSilently`, no `AppStore.sync()`).
- **Durable `device_id`** — `PlatformDevice.identifier` is now a Keychain UUID
  seeded once from the current `identifierForVendor` (IFV resets on full
  reinstall; Keychain survives). Existing rows keep their key via the seed.

**Backend (deployed, no app build):**
- **SEC-01** — `trial_granted_at` (migration `018`, idempotent + NULL-guarded
  backfill of all 327 existing users to `created_at`). New gate
  `shouldGrantTrial()` keys on `trial_granted_at`, not `subscription_expiry`
  (which support can clear) — mirrors Apple's permanent `isEligibleForIntroOffer`.
  Reclaim-by-`sub` (`FindUserByAppleID`) already existed and now no longer hands
  out a second trial. Active payers (future expiry) untouched.

## Verification

- Backend: `go build/vet/test ./...` green; `TestShouldGrantTrial` covers the
  bug case (already-granted + expired → no grant). On prod NL after deploy:
  327/327 users stamped, 0 NULL.
- iOS + macOS targets: `xcodebuild build` SUCCEEDED for both.

## Follow-ups

- `appAccountToken = UUID5(user_id)` on purchase to bind orphaned subs harder
  (BE-01a).
- Consider migrating the backend "free trial" to a real StoreKit introductory
  offer so Apple enforces one-per-Apple-ID natively (removes backend trial logic).
