package admin

import (
	"testing"
	"time"

	"github.com/chameleonvpn/chameleon/internal/db"
)

// TestToUserResponseCreatedAtIsZonedUTC locks down the timezone bug: created_at
// must be emitted as an RFC3339 instant in UTC, never a naive "2006-01-02 15:04"
// wall-clock string. A naive string carries no zone, so the admin SPA's
// new Date(...) parses it as the browser's local time (MSK, UTC+3) and inflates
// the "Xh ago" registered age by 3 hours. The fix matches last_seen.
func TestToUserResponseCreatedAtIsZonedUTC(t *testing.T) {
	msk := time.FixedZone("MSK", 3*60*60)
	// 08:33 UTC, expressed in MSK as 11:33+03:00.
	created := time.Date(2026, 5, 30, 11, 33, 0, 0, msk)

	r := toUserResponse(db.User{ID: 1, CreatedAt: created}, nil)

	if r.CreatedAt == nil {
		t.Fatal("created_at should be set for a non-zero CreatedAt")
	}
	got := *r.CreatedAt

	// Must be unambiguous: RFC3339 carries a zone designator. The old buggy
	// format ("2026-05-30 11:33") had a space separator and no zone, which
	// JS new Date() reads as local time.
	parsed, err := time.Parse(time.RFC3339, got)
	if err != nil {
		t.Fatalf("created_at %q is not RFC3339-parseable (regression: naive string, no zone): %v", got, err)
	}

	// Must represent the SAME absolute instant as the input — no wall-clock
	// shift. If serialization dropped the zone, parsed would differ by 3h.
	if !parsed.Equal(created) {
		t.Errorf("created_at instant drifted: input %s, serialized %q parsed to %s",
			created.UTC(), got, parsed.UTC())
	}

	// And specifically normalized to UTC (Z), matching audit.go / status.go.
	if want := "2026-05-30T08:33:00Z"; got != want {
		t.Errorf("created_at = %q, want %q (UTC RFC3339)", got, want)
	}
}

// TestToUserResponseCreatedAtZeroOmitted: a zero CreatedAt yields a nil field
// so the SPA renders "—" instead of a year-1 timestamp.
func TestToUserResponseCreatedAtZeroOmitted(t *testing.T) {
	r := toUserResponse(db.User{ID: 1}, nil)
	if r.CreatedAt != nil {
		t.Errorf("created_at should be nil for zero time, got %q", *r.CreatedAt)
	}
}
