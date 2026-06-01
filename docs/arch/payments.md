---
title: Payments
date: 2026-06-01
status: active
tags: [architecture, payments, freekassa, storekit]
---

# Payments

Two rails, one credit ledger. Facts (shop id, plans, IPs, env names, endpoint paths) live in [`../state/payment-providers.yaml`](../state/payment-providers.yaml); Apple IAP product state in [`../state/app-store.yaml`](../state/app-store.yaml#iaps). **Code is the source of truth** — this is just the map.

## Two rails (storefront split)

`PaywallRouter` picks the rail by `Storefront.current.countryCode`, not Locale:

- **non-CIS → StoreKit** — native IAP, 4 non-renewing subscriptions. See [`0005-non-renewable-iap-only.md`](../decisions/0005-non-renewable-iap-only.md).
- **RU/CIS → FreeKassa WebPaywall** — `WebPaywallView` opens the FK pay URL in **external Safari** (App Store-compliant: read as a third-party site visit, not in-app purchase). СБП / card / SberPay.

Routing rationale + the CIS storefront list: [`0003-storefront-routing.md`](../decisions/0003-storefront-routing.md).

## FreeKassa flow

```
WebPaywallView → POST /payment/initiate {plan, method, email}
  → backend: freekassa.CreateOrder → FK /orders/create (HMAC-SHA256 signed)
  → returns {paymentId, paymentURL}
  → iOS opens paymentURL in Safari; user pays
  → FK webhook → POST /api/webhooks/freekassa  ⇒  credit ledger (CreditDays)
  → iOS: on scenePhase=.active, single poll GET /payment/status/:payment_id
```

Email is mandatory (54-FZ receipt) and validated client-side. Polling is a **single** request on app foreground — the webhook usually lands first; no continuous loop.

Code: [`internal/api/mobile/payment.go`](../../backend/internal/api/mobile/payment.go) (initiate/status), [`internal/payments/freekassa/client.go`](../../backend/internal/payments/freekassa/client.go) (order create + `IPAllowed`), [`paymentid.go`](../../backend/internal/payments/freekassa/paymentid.go) (`app_{plan}_{user}_{nonce}`).

## Webhook validation

[`internal/api/mobile/payment_webhook.go`](../../backend/internal/api/mobile/payment_webhook.go) layers, in order:

1. **IP allowlist** — `RealIP()` against the FK notification IPs (allowlist in state YAML).
2. **MD5 signature** — `shopId:amount:secret2:orderId`, constant-time compare. Use FK's `AMOUNT` string verbatim — do not reformat. ([`signature.go`](../../backend/internal/payments/freekassa/signature.go)).
3. **Merchant id** must equal our shop id; **paymentId** must be `app_*` (bot payments routed elsewhere).

Reply must be plain `"YES"` or FK retries for hours.

## Refund → revoke (SEC-04)

Apple ASN v2 REFUND/REVOKE was previously log-only — refunded users kept access. Now [`MarkRefundedAndReconcile`](../../backend/internal/payments/credit.go) flips the charge to `refunded` and **recomputes `subscription_expiry` from the remaining completed ledger** (multi-source aware; sole charge → NULL = revoked; `REFUND_REVERSED` restores). Idempotent. Tests: [`credit_refund_test.go`](../../backend/internal/payments/credit_refund_test.go). Resolved 2026-06-01 — see SEC-04 in [`../roadmap.yaml`](../roadmap.yaml).
