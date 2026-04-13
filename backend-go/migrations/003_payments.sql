-- Unified payments ledger. All credit sources (Apple IAP, FreeKassa/SBP, admin grants,
-- promo bonuses) go through internal/payments.CreditDays, which writes one row here per
-- successful charge and extends users.subscription_expiry in the same transaction.
--
-- Idempotency: UNIQUE(source, charge_id). A duplicate webhook for the same charge
-- returns alreadyApplied=true without double-crediting.

CREATE TABLE IF NOT EXISTS payments (
    id              BIGSERIAL PRIMARY KEY,
    user_id         INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    source          VARCHAR(32) NOT NULL,   -- apple_iap | freekassa | admin | promo
    provider        VARCHAR(64),            -- freekassa merchant label (fk / ai_kassa / ...)
    charge_id       VARCHAR(255) NOT NULL,  -- provider's transaction id (original_transaction_id for Apple)
    days            INTEGER NOT NULL,
    amount_minor    BIGINT,                 -- amount in minor units (kopecks/cents), nullable for admin/promo
    currency        VARCHAR(8),             -- ISO 4217, nullable for admin/promo
    status          VARCHAR(16) NOT NULL DEFAULT 'completed', -- completed | refunded
    metadata        JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS payments_source_charge_uniq
    ON payments(source, charge_id);

CREATE INDEX IF NOT EXISTS payments_user_created_idx
    ON payments(user_id, created_at DESC);
