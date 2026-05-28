---
title: Storefront-based paywall routing (StoreKit vs web)
date: 2026-04-21
status: active
tags: [payments, ios, storekit, freekassa]
---

# 0003 — Storefront routing

## Context

App Store Guideline 3.1.1: digital goods sold to users outside regions where alternative processors are permitted **must** go through StoreKit. But:

- Russian (and several CIS) StoreKit is broken since 2022 — Apple suspended RU transactions, and even on accounts that exist, RU bank cards are mostly rejected by Apple's payment processor.
- We have a working web paywall via **FreeKassa** (SBP, mir-cards) that serves RU users fine.

We need to satisfy Apple while not killing RU revenue.

## Decision

Route the paywall based on `StoreKit.Storefront.current.countryCode`, **not** `Locale.current.regionCode`:

- **CIS storefronts** (RUS, KAZ, BLR, UZB, UKR, AZE, ARM, GEO, KGZ, TJK, TKM, MDA — ISO-3 codes) → `WebPaywallView` (FreeKassa hosted page, returns to app via custom URL scheme).
- **Everyone else** → `PaywallView` (StoreKit 2 native).

Why `Storefront` over `Locale`:

- A user with the iPhone language set to RU but logged in on a US App Store account *can* buy via StoreKit and we want them to. `Storefront` reflects what Apple's payment processor sees; `Locale` reflects UI preference.
- A user in Georgia with a Russian App Store account *can't* buy via StoreKit easily — `Storefront=RUS` correctly routes them to the web paywall.

Implementation: [`clients/apple/MadFrogVPN/Views/PaywallRouter.swift`](../../clients/apple/MadFrogVPN/Views/PaywallRouter.swift). Reads `await Storefront.current` once on appear, caches in a `@State`.

## Consequences

- Apple compliance: non-CIS users go through Apple — Guideline 3.1.1 satisfied.
- RU revenue: not lost to broken StoreKit — web paywall works for SBP cards.
- Two payment backends to maintain: Apple App Store Server Notifications V2 (`backend/internal/payments/apple/`) and FreeKassa webhook (`backend/internal/payments/freekassa/`).
- Two telemetry paths: StoreKit transactions → backend `verifySubscription` JWS; FreeKassa → webhook → `payments` table directly.

## Trade-offs accepted

- A US user travelling in Russia with a US App Store account sees StoreKit (correct).
- A RU user who switched their account to US storefront to buy "elsewhere" sees StoreKit (also correct — they made that choice).
- Edge case: user creates RU storefront then deletes account → next launch shows wrong paywall briefly until cache invalidates. Acceptable.

## Status

Active. Migration to auto-renewable subscriptions (Subscription Groups) tracked separately in [`../PLAN-auto-renewing-migration.md`](../PLAN-auto-renewing-migration.md) (legacy file; will become a future ADR).
