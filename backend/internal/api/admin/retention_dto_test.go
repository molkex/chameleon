package admin

import (
	"testing"

	"github.com/chameleonvpn/chameleon/internal/db"
)

// toRetentionDTO is pure (no DB) — verify the derived rates + divide-by-zero guards.
// A9 (PRODUCT-MATURITY-LOOP).
func TestToRetentionDTO(t *testing.T) {
	got := toRetentionDTO(&db.RetentionStats{
		ActiveSubscribers: 100,
		Expired7d:         5,
		Expired30d:        20,
		EverTrialed:       200,
		PaidUsers:         40,
		RepeatPayers:      10,
		TrialConverted:    30,
	})
	if got.TrialConversionPct != 15.0 { // 30/200
		t.Errorf("TrialConversionPct = %v, want 15.0", got.TrialConversionPct)
	}
	if got.RepeatPurchasePct != 25.0 { // 10/40
		t.Errorf("RepeatPurchasePct = %v, want 25.0", got.RepeatPurchasePct)
	}
	if got.ActiveSubscribers != 100 || got.Expired7d != 5 || got.PaidUsers != 40 {
		t.Errorf("raw counts not passed through: %+v", got)
	}
}

func TestToRetentionDTOZeroGuards(t *testing.T) {
	// No trials, no payers → no division, no NaN/Inf.
	got := toRetentionDTO(&db.RetentionStats{})
	if got.TrialConversionPct != 0 || got.RepeatPurchasePct != 0 {
		t.Errorf("zero stats should give 0 rates, got %+v", got)
	}
	// nil → zero DTO, no panic.
	if z := toRetentionDTO(nil); z.ActiveSubscribers != 0 {
		t.Errorf("nil should give zero DTO, got %+v", z)
	}
}

func TestRound1(t *testing.T) {
	cases := map[float64]float64{
		15.04:     15.0,
		15.05:     15.1,
		33.333333: 33.3,
		66.666666: 66.7,
		0:         0,
	}
	for in, want := range cases {
		if got := round1(in); got != want {
			t.Errorf("round1(%v) = %v, want %v", in, got, want)
		}
	}
}
