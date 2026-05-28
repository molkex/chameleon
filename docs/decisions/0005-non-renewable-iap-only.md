---
title: Non-renewing subscriptions only (no auto-renewable, no Subscription Groups)
date: 2026-04-26
status: active
tags: [payments, ios, storekit, iap]
---

# 0005 — Non-renewing subscriptions only

## Context

When configuring IAPs in App Store Connect we had two paths:

1. **Non-renewing subscription** — user pays once, gets N days of access, then nothing happens until they buy again.
2. **Auto-renewable subscription** — Apple auto-charges on renewal, manages cancellation in iOS Settings, requires a Subscription Group.

Auto-renewable has nicer UX (no manual re-purchase) but is significantly more setup:

- Must create a Subscription Group + define renewal periods + introductory pricing rules.
- Backend must handle `DID_RENEW`, `EXPIRED`, `REVOKE`, `GRACE_PERIOD` notifications.
- StoreKit `Transaction.updates` listener is required so renewals are picked up on cold start.
- Family Sharing flag, Ask to Buy, billing retry logic all interact.

## Decision

**Ship with non-renewing subscriptions first.** Apple ID `com.madfrog.vpn.sub.{30,90,180,365}days`. User flow:

1. Tap product → StoreKit purchase sheet → JWS returned.
2. App POSTs JWS to backend `/api/v1/mobile/subscription/verify`.
3. Backend verifies JWS chain against Apple root, extracts `productId`, extends `users.subscription_expiry` by the corresponding days.
4. App calls `Transaction.finish()` after backend confirms.

No auto-renewal. When the period ends, the user sees the paywall again.

## Why not auto-renewable from day one

- **Simpler backend.** `payments.charge_id = transactionId`, idempotent insert. No state machine for renewal events.
- **Simpler iOS.** `Transaction.updates` listener still exists (handles refunds, recovery from crash mid-purchase) but doesn't need to differentiate renewals.
- **Easier App Review.** First-time IAP submissions are tricky — fewer moving parts → fewer rejection vectors.
- **No commitment.** Users decide each period whether to re-buy. Higher churn ceiling but no Apple-managed cancellation flow to support.

## Consequences

- LTV/ARPU lower than auto-renew (industry-wide observation: 30-50% drop after first period).
- Marketing must remind users to renew (email / push notification).
- When we want to migrate, see [`../PLAN-auto-renewing-migration.md`](../PLAN-auto-renewing-migration.md) — Apple does NOT allow direct conversion of non-renewing to auto-renewable; we'd add NEW product IDs and let old ones expire.

## Status

Active. Migration to auto-renewable considered but not scheduled. Re-evaluate after 6 months of revenue data.
