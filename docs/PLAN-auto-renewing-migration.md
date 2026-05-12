# Migration Plan: Non-Renewing → Auto-Renewing Subscriptions

**Date:** 2026-05-12
**Status:** Plan, awaiting approval before implementation

## Overview

Switch MadFrog VPN (`com.madfrog.vpn`) from four non-renewing subscription products (currently frozen in `DEVELOPER_ACTION_NEEDED` state in ASC) to four auto-renewing subscriptions in a single subscription group. The StoreKit 2 + JWS verification stack is largely unchanged on both iOS and Go backend, **but** the payments ledger `chargeID` scheme has a critical bug that must be fixed before auto-renewing products go live, and the paywall legal footer must flip to Apple-mandated auto-renew disclosure.

---

## 1. iOS Code Changes

**File:** `clients/apple/MadFrogVPN/Models/SubscriptionManager.swift`

**Lines 26-31 — replace product ID constants:**

```swift
// OLD
static let product30  = "com.madfrog.vpn.sub.30days"
static let product90  = "com.madfrog.vpn.sub.90days"
static let product180 = "com.madfrog.vpn.sub.180days"
static let product365 = "com.madfrog.vpn.sub.365days"
static let allProductIDs: [String] = [product30, product90, product180, product365]

// NEW
static let product1m  = "com.madfrog.vpn.sub.month"
static let product3m  = "com.madfrog.vpn.sub.3month"
static let product6m  = "com.madfrog.vpn.sub.6month"
static let product1y  = "com.madfrog.vpn.sub.year"
static let allProductIDs: [String] = [product1m, product3m, product6m, product1y]
```

No other Swift changes are needed. StoreKit 2 `Transaction` and `Product` APIs are identical for auto-renewing and non-renewing types:

- `Transaction.updates` listener (line 169) already handles renewals — Apple delivers a new verified JWS on each billing date.
- `updatePremiumStatus()` (line 194-207): `expirationDate > Date()` check at line 200 is correct for auto-renewing.
- `restorePurchases()` via `AppStore.sync()` + `Transaction.currentEntitlements` works unchanged.

**PaywallView.swift** — no logic changes. `product.displayName` and `product.displayPrice` from StoreKit auto-populate billing-period suffix when configured in ASC.

---

## 2. Backend Changes

### 2a. Product map — add new IDs

**File:** `backend/internal/api/mobile/subscription.go`, lines 19-24

```go
var productDays = map[string]int{
    // Auto-renewing (new products)
    "com.madfrog.vpn.sub.month":  30,
    "com.madfrog.vpn.sub.3month": 90,
    "com.madfrog.vpn.sub.6month": 180,
    "com.madfrog.vpn.sub.year":   365,
    // Non-renewing (legacy — keep until all 365-day old purchases expire ≈ 2027-05)
    "com.madfrog.vpn.sub.30days":  30,
    "com.madfrog.vpn.sub.90days":  90,
    "com.madfrog.vpn.sub.180days": 180,
    "com.madfrog.vpn.sub.365days": 365,
}
```

### 2b. 🚨 Critical chargeID fix for renewals (P0)

**Problem:** `/verify` endpoint (`subscription.go` line 119) and `DID_RENEW` webhook handler (`subscription_notification.go` line 133) use `originalTransactionId` as `chargeID`. For auto-renewing subs every renewal has the **same** `originalTransactionId`, so renewal #2+ hits `ON CONFLICT DO NOTHING` in `CreditDays`, then falls into `ReconcileFromLedger` which computes `MIN(created_at) + SUM(days)` — a value that never extends past the original purchase date. **Users who auto-renew will silently lose access after their first month.**

**Fix:**

Add to `subscription.go` (after `productDays`):

```go
var autoRenewingProducts = map[string]bool{
    "com.madfrog.vpn.sub.month":  true,
    "com.madfrog.vpn.sub.3month": true,
    "com.madfrog.vpn.sub.6month": true,
    "com.madfrog.vpn.sub.year":   true,
}

func isAutoRenewing(productID string) bool {
    return autoRenewingProducts[productID]
}
```

In `VerifySubscription` (`subscription.go` line 119) and `creditFromNotification` (`subscription_notification.go` line 130-135) — switch chargeID for auto-renewing:

```go
chargeID := tx.OriginalTransactionID
if isAutoRenewing(tx.ProductID) {
    chargeID = tx.TransactionID // each renewal = distinct row
}
```

`FindUserByOriginalTransactionID` stays unchanged (correct user lookup key).

### 2c. Test

Add to `backend/internal/api/mobile/subscription_test.go`: call `/verify` twice with same `originalTransactionId` but two distinct `transactionId` values, assert two distinct rows in `payments` and `subscription_expiry` extended twice.

---

## 3. App Store Connect Changes

### 3a. Create subscription group

ASC → MadFrog VPN → In-App Purchases → Manage → **Subscription Group** with reference name "Pro".

### 3b. Create four auto-renewing products

| Product ID | Duration | Level | Suggested USD |
|---|---|---|---|
| `com.madfrog.vpn.sub.month` | 1 month | 4 | $4.99 |
| `com.madfrog.vpn.sub.3month` | 3 months | 3 | $11.99 |
| `com.madfrog.vpn.sub.6month` | 6 months | 2 | $19.99 |
| `com.madfrog.vpn.sub.year` | 1 year | 1 | $34.99 |

Level 1 = highest value (so monthly → yearly = upgrade, not downgrade). Per product: EN + RU display name, short description, review screenshot of paywall.

### 3c. Old frozen products

Leave them in `DEVELOPER_ACTION_NEEDED` — don't delete (would break Restore for existing buyers). Remove from `productDays` map after 2027-05.

### 3d. Free trial (optional)

Current guest 3-day trial is backend device_id gate — works for both types. For Apple-native trial, add 3-day free trial offer on `com.madfrog.vpn.sub.month`.

---

## 4. Existing Users

- **Active non-renewing buyers:** `subscription_expiry` runs out naturally. Then they hit paywall with new auto-renewing products.
- **Guests (3-day trial):** unaffected — gate is backend-only.
- **In-flight non-renewing purchases:** old product IDs stay in `productDays`, so `/verify` still accepts their JWS.
- **Restore Purchases for old buyers:** `Transaction.currentEntitlements` returns all transactions including old non-renewing. Keep old IDs in iOS `allProductIDs` until 2027-05 cleanup.

---

## 5. Marketing Copy Changes

**File:** `clients/apple/MadFrogVPN/Resources/en.lproj/Localizable.strings`, line 154

```
// OLD
"paywall.legal" = "Charged to your Apple ID. Subscription does not auto-renew — it is a one-time purchase for the selected period.";

// NEW (Apple-required formula)
"paywall.legal" = "Payment will be charged to your Apple ID at confirmation of purchase. Subscription automatically renews unless cancelled at least 24 hours before the end of the current period. Your account will be charged for renewal within 24 hours prior to the end of the current period. Manage or cancel subscriptions in your App Store account settings. Any unused portion of a free trial will be forfeited upon purchase of a subscription.";
```

**File:** `clients/apple/MadFrogVPN/Resources/ru.lproj/Localizable.strings`, line 154

```
"paywall.legal" = "Оплата списывается с вашего Apple ID при подтверждении покупки. Подписка автоматически продлевается, если не отменена за 24 часа до конца текущего периода. Управлять подпиской и отменить её можно в настройках аккаунта App Store. Неиспользованная часть пробного периода аннулируется при оформлении подписки.";
```

**App Store description in ASC:** remove "does not auto-renew" / "one-time purchase". Add auto-renewal disclosure sentence + link to subscription terms.

---

## 6. Migration Sequence

1. **Backend (deploy first):** Add new product IDs to `productDays`, implement `isAutoRenewing()`, apply `chargeID` fix, add test. Deploy to DE+NL. Backward-compatible.
2. **ASC product creation:** Create subscription group + 4 auto-renewing products. Wait for "Ready to Submit" (1-2 business days).
3. **iOS build (build 54):** Update `allProductIDs` + legal copy (EN+RU). Build, upload to TestFlight. Sandbox E2E: purchase monthly, wait ~5 min for accelerated renewal, verify TWO distinct rows in `payments` table, `subscription_expiry` extended twice.
4. **App Store submission:** Submit with new IAPs attached, updated description. Update App Privacy if needed.
5. **After approval:** Monitor payments ledger. Old non-renewing rows = `originalTransactionId` chargeID, new = `transactionId` chargeID. Both valid UUIDs, no collision.
6. **Cleanup (≥ 2027-05):** Remove old product IDs from backend + iOS.

---

## 7. Estimated Effort

| Area | Hours |
|---|---|
| Backend: productDays + chargeID fix + test | 3 |
| iOS: product ID constants + legal copy (EN+RU) | 1 |
| ASC: subscription group + 4 products + screenshots | 2 |
| TestFlight Sandbox E2E (renewal flow) | 2 |
| App Store submission + description update | 1 + async review wait |
| **Total active work** | **~9 h** |

---

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| chargeID bug ships without fix → users lose access on renewal #1 | Sandbox E2E in step 3 catches it. Do NOT ship without verifying two distinct `charge_id` rows on accelerated renewal. |
| Subscription level order wrong (yearly = level 4 instead of 1) | Verify upgrade flow in Sandbox. Monthly→yearly must show as upgrade. |
| Old products not in `allProductIDs` → Restore breaks for old buyers | Keep BOTH old + new in `allProductIDs` and `productDays` until 2027-05. |
| Apple review rejection for VPN | Subscription group review screenshots show paywall clearly. Description has no circumvention language. `paywall.legal` matches required formula verbatim. |
