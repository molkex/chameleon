package mobile

import (
	"testing"
	"time"

	"github.com/chameleonvpn/chameleon/internal/db"
)

// REFUND-NULL-EXPIRY-GATE (2026-06-17). hasActiveSubscription is the ONE
// canonical predicate the /config gate, the VPN roster, and the trial gate must
// agree on. The critical case is NULL expiry: it means NO coverage (never
// subscribed / refunded-to-zero), NOT "lifetime" — so it must gate the user out
// and trigger the paywall.
func TestHasActiveSubscription(t *testing.T) {
	now := time.Now()
	future := now.Add(24 * time.Hour)
	past := now.Add(-24 * time.Hour)

	cases := []struct {
		name   string
		expiry *time.Time
		want   bool
	}{
		{"future expiry is active", &future, true},
		{"past expiry is not active", &past, false},
		{"NULL expiry is NOT active (no coverage, not lifetime)", nil, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			u := &db.User{SubscriptionExpiry: tc.expiry}
			if got := hasActiveSubscription(u); got != tc.want {
				t.Errorf("hasActiveSubscription(expiry=%v) = %v, want %v", tc.expiry, got, tc.want)
			}
		})
	}
}

// SUBSCRIPTION-ON-AUTH (2026-06-17): the auth response carries the subscription
// expiry as unix-seconds so the client applies it the instant sign-in succeeds.
func TestSubExpiryUnix(t *testing.T) {
	if subExpiryUnix(nil) != nil {
		t.Error("nil expiry must map to nil (no coverage)")
	}
	ts := time.Unix(1_800_000_000, 0)
	got := subExpiryUnix(&ts)
	if got == nil || *got != 1_800_000_000 {
		t.Errorf("subExpiryUnix(%v) = %v, want 1800000000", ts, got)
	}
}
