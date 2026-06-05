package promo

import (
	"testing"
	"time"
)

func ptrInt(n int) *int { return &n }

func TestNormalize(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"  promo ", "PROMO"}, {"Save50", "SAVE50"}, {"", ""},
	} {
		if got := Normalize(c.in); got != c.want {
			t.Errorf("Normalize(%q)=%q want %q", c.in, got, c.want)
		}
	}
}

func TestValidate(t *testing.T) {
	now := time.Date(2026, 6, 5, 12, 0, 0, 0, time.UTC)
	past := now.Add(-time.Hour)
	future := now.Add(time.Hour)

	cases := []struct {
		name      string
		code      *Code
		redeemed  bool
		want      Reason
	}{
		{"nil → not found", nil, false, NotFound},
		{"active unlimited → ok", &Code{Active: true}, false, OK},
		{"inactive", &Code{Active: false}, false, Inactive},
		{"expired", &Code{Active: true, ExpiresAt: &past}, false, Expired},
		{"in window", &Code{Active: true, ExpiresAt: &future}, false, OK},
		{"exhausted", &Code{Active: true, MaxUses: ptrInt(10), UsedCount: 10}, false, Exhausted},
		{"under max", &Code{Active: true, MaxUses: ptrInt(10), UsedCount: 9}, false, OK},
		{"per-user-once, already used", &Code{Active: true, PerUserOnce: true}, true, AlreadyUsed},
		{"per-user-once, fresh user", &Code{Active: true, PerUserOnce: true}, false, OK},
		{"not per-user, reused ok", &Code{Active: true, PerUserOnce: false}, true, OK},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := Validate(c.code, now, c.redeemed); got != c.want {
				t.Errorf("Validate = %q, want %q", got, c.want)
			}
		})
	}
}

func TestValidatePrecedence(t *testing.T) {
	// inactive beats expired beats exhausted — first failing rule wins.
	now := time.Now()
	past := now.Add(-time.Hour)
	c := &Code{Active: false, ExpiresAt: &past, MaxUses: ptrInt(0)}
	if got := Validate(c, now, true); got != Inactive {
		t.Errorf("expected Inactive to win, got %q", got)
	}
}

func TestDiscountedPrice(t *testing.T) {
	cases := []struct {
		base, pct, want int
	}{
		{229, 50, 114},  // off=round(114.5)=115 → 229-115=114
		{229, 0, 229},   // no discount
		{229, 100, 1},   // capped at 1₽, never free
		{229, 35, 149},  // off=round(80.15)=80 → 229-80=149
		{599, 50, 299},  // off=round(299.5)=300 → 599-300=299
		{1999, 10, 1799},
		{0, 50, 0},      // zero base untouched
		{229, -5, 229},  // negative pct ignored
	}
	for _, c := range cases {
		if got := DiscountedPrice(c.base, c.pct); got != c.want {
			t.Errorf("DiscountedPrice(%d, %d)=%d want %d", c.base, c.pct, got, c.want)
		}
	}
}

func TestDiscountedPriceNeverBelowOne(t *testing.T) {
	if got := DiscountedPrice(1, 99); got < 1 {
		t.Errorf("price must floor at 1, got %d", got)
	}
}
