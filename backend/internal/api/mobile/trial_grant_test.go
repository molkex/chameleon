package mobile

import (
	"testing"
	"time"

	"github.com/chameleonvpn/chameleon/internal/db"
)

// TestShouldGrantTrial locks down SEC-01 (2026-06-01): a free trial is granted
// at most once per identity. The gate is trial_granted_at, NOT
// subscription_expiry — so an expired user who already consumed their trial
// can never harvest a new one by re-authenticating.
func TestShouldGrantTrial(t *testing.T) {
	past := time.Now().Add(-72 * time.Hour)
	future := time.Now().Add(72 * time.Hour)
	granted := time.Now().Add(-30 * 24 * time.Hour)

	tests := []struct {
		name         string
		trialGranted *time.Time
		subExpiry    *time.Time
		wantGrant    bool
	}{
		{
			name:         "brand-new identity (never granted, no expiry) → grant",
			trialGranted: nil,
			subExpiry:    nil,
			wantGrant:    true,
		},
		{
			name:         "never granted but somehow expired → grant once",
			trialGranted: nil,
			subExpiry:    &past,
			wantGrant:    true,
		},
		{
			name:         "active payer (future expiry) → never a trial",
			trialGranted: nil,
			subExpiry:    &future,
			wantGrant:    false,
		},
		{
			name:         "THE BUG: already granted + expired → NO new trial",
			trialGranted: &granted,
			subExpiry:    &past,
			wantGrant:    false,
		},
		{
			name:         "already granted + no expiry → no new trial",
			trialGranted: &granted,
			subExpiry:    nil,
			wantGrant:    false,
		},
		{
			name:         "already granted + active payer → no new trial",
			trialGranted: &granted,
			subExpiry:    &future,
			wantGrant:    false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			u := &db.User{SubscriptionExpiry: tt.subExpiry, TrialGrantedAt: tt.trialGranted}
			if got := shouldGrantTrial(u); got != tt.wantGrant {
				t.Errorf("shouldGrantTrial() = %v, want %v", got, tt.wantGrant)
			}
		})
	}
}
