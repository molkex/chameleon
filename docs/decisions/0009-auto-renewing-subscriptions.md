---
title: Migrate to auto-renewing subscriptions (supersedes 0005)
date: 2026-05-29
status: active
supersedes: 0005
tags: [payments, ios, storekit, iap, subscriptions]
---

# 0009 — Auto-renewing subscriptions

Supersedes [`0005-non-renewable-iap-only.md`](./0005-non-renewable-iap-only.md).

## Context

ADR-0005 (2026-04-26) shipped **non-renewing** subscriptions to keep the first
launch simple. After the 2026-05-28 organic spike (47 → 142 users in a day) the
trade-off it called out — *"LTV/ARPU lower than auto-renew (30-50% drop after
first period)"* — became the main thing worth fixing: with real volume, the
recurring-revenue gap compounds, and the non-renewing flow makes the user
re-decide every period (high churn, manual renewal reminders).

The backend cost that 0005 wanted to avoid (renewal state machine) was already
paid down in a separate change: `subscription.go` now carries both product sets
and the `appleChargeID()` / `isAutoRenewing()` logic, and the P0 ledger bug
(renewals colliding on `originalTransactionId`) is fixed and unit-tested
(`subscription_chargeid_test.go`). So the blocker to auto-renew is gone.

## Decision

**Migrate to auto-renewing subscriptions** in a single ASC subscription group
`Pro` (id `22119908`). Four products, one per duration:

| Product ID | Duration | ASC id | Price (USD base) |
|---|---|---|---|
| `com.madfrog.vpn.sub.month`  | 1 month  | 6774348610 | $2.99 |
| `com.madfrog.vpn.sub.3month` | 3 months | 6774348751 | $7.99 |
| `com.madfrog.vpn.sub.6month` | 6 months | 6774348464 | $14.99 |
| `com.madfrog.vpn.sub.year`   | 1 year   | 6774348465 | $24.99 |

Price ladder gives a cheaper effective monthly rate the longer the commitment
(month $2.99/mo → year ~$2.08/mo). Prices equalized to all 175 territories from
the USD base; availability = all territories + `availableInNewTerritories`.

The legacy non-renewing products (`com.madfrog.vpn.sub.{30,90,180,365}days`)
are **not deleted** — see Consequences.

## What changed

- **Backend** (already merged): `productDays` carries both new + legacy IDs;
  `autoRenewingProducts` / `isAutoRenewing()` / `appleChargeID()` pick
  `transactionId` (not `originalTransactionId`) as `payments.charge_id` for
  auto-renewing products so renewal #2+ doesn't collide on
  `UNIQUE(source, charge_id)`.
- **iOS** (`SubscriptionManager.swift`): `displayProductIDs` = the 4 new
  auto-renewing products (what the paywall shows); `allProductIDs` =
  `displayProductIDs` + the 4 legacy IDs (recognized for entitlement / Restore).
  `loadProducts()` displays `displayProductIDs`; restore / entitlement / sync
  filters use `allProductIDs`.
- **Paywall legal copy** (`paywall.legal`, en + ru): flipped from
  "does not auto-renew — one-time purchase" to the Apple-required auto-renewal
  disclosure (renews unless cancelled 24h before period end, manage in App Store
  settings). StoreKit 2 `Transaction.updates` already handles renewals — no
  other Swift logic change needed.
- **ASC**: group `Pro` + 4 products + EN/RU localizations + prices +
  availability all created (mostly via ASC API, prices via the web UI because
  the price-create API kept returning 409 on the price-point relationship).

## Consequences

- **Legacy products stay** until the last 365-day non-renewing purchase expires
  (≈ 2027-05). Deleting them would break Restore for existing buyers. Their IDs
  remain in backend `productDays` and iOS `allProductIDs` (not `displayProductIDs`)
  until then.
- **First-subscription review is bundled with a build.** Apple reviews the first
  subscription of a group together with an app binary, so these 4 ship + submit
  with iOS build 91 — they cannot be approved standalone.
- **Storefront routing unchanged** (ADR-0003): RU/CIS → `WebPaywallView`
  (FreeKassa/SBP), everyone else → StoreKit. The auto-renewing products only
  affect the StoreKit route.
- A free trial is still the backend device-id gate (not a StoreKit intro offer),
  so the `paywall.legal` copy omits the "unused free-trial portion forfeited"
  sentence. Add it if/when a StoreKit intro offer is configured.

## Status

Active. Rollout: ships with iOS build 1.0.28 / 91. After approval, monitor the
payments ledger — legacy rows use `originalTransactionId` as `charge_id`, new
auto-renewing rows use `transactionId`; both are distinct so no collision.
