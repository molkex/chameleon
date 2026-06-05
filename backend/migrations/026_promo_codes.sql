-- 026_promo_codes.sql
-- Promo codes for the FreeKassa web paywall (PROMO-CODES). A code applies a
-- percentage discount to a plan's price; the discounted amount is what we ask
-- FreeKassa to charge and what the webhook verifies against — so the discount
-- must be PERSISTED per pending payment (the payment flow is otherwise stateless:
-- payment_id encodes plan+user, the webhook re-derives price from config).

CREATE TABLE IF NOT EXISTS promo_codes (
    id            BIGSERIAL PRIMARY KEY,
    code          TEXT NOT NULL UNIQUE,                 -- stored UPPER-cased
    discount_pct  INT  NOT NULL CHECK (discount_pct BETWEEN 1 AND 100),
    active        BOOLEAN NOT NULL DEFAULT TRUE,
    per_user_once BOOLEAN NOT NULL DEFAULT TRUE,        -- one redemption per user
    max_uses      INT,                                  -- NULL = unlimited
    used_count    INT NOT NULL DEFAULT 0,
    expires_at    TIMESTAMPTZ,                          -- NULL = never expires
    note          TEXT,
    created_by    TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- One pending-payment intent per discounted order. Keyed by the app payment_id
-- so the webhook can look up the EXPECTED (discounted) amount + the code to
-- redeem. Non-promo payments create no intent (webhook falls back to plan price).
CREATE TABLE IF NOT EXISTS payment_intents (
    payment_id    TEXT PRIMARY KEY,
    user_id       BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    plan_id       TEXT NOT NULL,
    amount_rub    INT  NOT NULL,                        -- the discounted amount charged
    promo_code_id BIGINT REFERENCES promo_codes(id) ON DELETE SET NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- A successful redemption. UNIQUE(code,user) enforces per-user-once at the DB
-- level; recorded by the webhook after CreditDays succeeds.
CREATE TABLE IF NOT EXISTS promo_redemptions (
    id            BIGSERIAL PRIMARY KEY,
    promo_code_id BIGINT NOT NULL REFERENCES promo_codes(id) ON DELETE CASCADE,
    user_id       BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    payment_id    TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (promo_code_id, user_id)
);
