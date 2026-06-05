// Package promo holds the pure, dependency-free promo-code domain logic:
// redeemability validation and discount arithmetic. The DB layer
// (internal/db/promo.go) and the HTTP handlers build a Code value and call
// these — keeping the rules unit-testable without a database or Echo.
package promo

import (
	"strings"
	"time"
)

// Code is the minimal view of a promo code needed to decide redeemability.
type Code struct {
	ID          int64
	Code        string
	DiscountPct int
	Active      bool
	MaxUses     *int // nil = unlimited
	UsedCount   int
	PerUserOnce bool
	ExpiresAt   *time.Time // nil = never expires
}

// Reason is empty ("") when a code is valid, otherwise a stable machine code.
type Reason string

const (
	OK          Reason = ""
	NotFound    Reason = "not_found"
	Inactive    Reason = "inactive"
	Expired     Reason = "expired"
	Exhausted   Reason = "exhausted"
	AlreadyUsed Reason = "already_used"
)

// Message is a human (RU) explanation for a reason — surfaced to the client.
func (r Reason) Message() string {
	switch r {
	case OK:
		return "Промокод применён"
	case NotFound:
		return "Промокод не найден"
	case Inactive:
		return "Промокод отключён"
	case Expired:
		return "Срок действия промокода истёк"
	case Exhausted:
		return "Лимит использований промокода исчерпан"
	case AlreadyUsed:
		return "Вы уже использовали этот промокод"
	default:
		return "Промокод недоступен"
	}
}

// Normalize trims + upper-cases a code so "  promo " and "PROMO" match.
func Normalize(code string) string {
	return strings.ToUpper(strings.TrimSpace(code))
}

// Validate checks whether a code may be redeemed by a user right now.
// code == nil ⇒ NotFound. userAlreadyRedeemed gates the PerUserOnce rule.
func Validate(code *Code, now time.Time, userAlreadyRedeemed bool) Reason {
	if code == nil {
		return NotFound
	}
	if !code.Active {
		return Inactive
	}
	if code.ExpiresAt != nil && now.After(*code.ExpiresAt) {
		return Expired
	}
	if code.MaxUses != nil && code.UsedCount >= *code.MaxUses {
		return Exhausted
	}
	if code.PerUserOnce && userAlreadyRedeemed {
		return AlreadyUsed
	}
	return OK
}

// DiscountedPrice applies pct off base (rubles), rounded to the nearest ruble
// and floored at 1₽ (a promo never makes a paid plan free — that would route
// the user past the payment provider entirely).
func DiscountedPrice(baseRub, pct int) int {
	if pct <= 0 || baseRub <= 0 {
		return baseRub
	}
	if pct >= 100 {
		return 1
	}
	off := (baseRub*pct + 50) / 100 // +50 → round to nearest
	price := baseRub - off
	if price < 1 {
		price = 1
	}
	return price
}
