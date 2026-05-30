---
date: 2026-05-30
severity: low
component: admin dashboard (payments widget) + payments ledger
status: resolved
---

# Payments dashboard counted dev/sandbox/admin rows as real revenue

## Symptom

The "Оплаты" widget showed **848 ₽ / 6 оплат / 4 плательщика** with breakdown
FreeKassa 3 (848₽), Apple IAP 3 (без суммы), Admin 1. Operator: only **2** of
these were real customer payments.

## Investigation

Full ledger (8 rows). Reconciled every figure against
[`backend/internal/db/payments.go`](../../backend/internal/db/payments.go):

| id | source | amount | user | status | verdict |
|----|--------|-------:|------|--------|---------|
| 17 | freekassa | 229₽ | 159167 | completed | real |
| 16 | freekassa | 599₽ | 159014 | completed | real |
| 13 | freekassa | 20₽ | 12351 | completed | dev test (12351 = dev acct) |
| 14 | apple_iap | — | 68977 | completed | sandbox |
| 7  | apple_iap | — | 12351 | completed | sandbox (dev) |
| 4  | apple_iap | — | 12351 | completed | sandbox (dev) |
| 3  | admin | — | 12351 | completed | admin grant (dev test) |
| 15 | admin | — | 158990 | refunded | accidental grant, already refunded |

**Root cause of the sandbox rows:** Apple IAP was historically accepted with
`payments.apple.allow_sandbox: true` in production (flagged in
`docs/AUDIT_2026-05-26_GPT.md`). The payments table has **no environment
column**, so Sandbox-signed StoreKit transactions were recorded as ordinary
`completed` apple_iap payments, indistinguishable from real sales. Production
config now has `allow_sandbox: false` (verified live in the container's mounted
`/etc/chameleon/config.yaml`) — new sandbox transactions are rejected, so this
no longer accumulates. The remaining junk was historical.

## Fix

Operator-driven exclusion via a new `status = 'void'`:

1. **Code** (commit `5b4d1b3`): money rollups (`PaymentsBlock`, funnel,
   unique-payers) already filter `status IN ('completed','refunded')`, so void
   is excluded automatically. `RecentPayments` had no status filter — added
   `WHERE status <> 'void'` so voided rows don't resurface in the "last
   payments" table. Integration tests seed a void row and assert it neither
   moves a total nor appears in the list.

2. **Data** (NL prod, backed up to `/root/payments-backup-20260530-090151.sql`
   first): voided rows 3,4,7,13,14,15, preserving the original status in
   `metadata.voided_from`:

   ```sql
   UPDATE payments
   SET status = 'void',
       metadata = COALESCE(metadata,'{}'::jsonb) || jsonb_build_object(
         'voided_from', status,
         'void_reason', 'dev/sandbox/test — excluded from dashboard 2026-05-30',
         'voided_by', 'admin-cleanup')
   WHERE id IN (3,4,7,13,14,15);
   ```

Subscriptions are unaffected — granted days live on `users.subscription_expiry`,
not the ledger.

## Result (verified on live /admin/stats/dashboard)

ALL period: **828 ₽ / 2 оплат / 2 плательщика**, by_source = FreeKassa only;
recent_transactions = the two real rows (229₽, 599₽).

## Follow-ups (not done)

- No durable test/sandbox marker on payments. If the dev tests via real
  FreeKassa or a future sandbox path, junk can reappear and needs manual
  voiding. A proper `environment` column on apple_iap (Production/Sandbox, the
  verifier already exposes it) + a test-account flag would make this automatic.
