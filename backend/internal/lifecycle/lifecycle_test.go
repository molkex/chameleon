package lifecycle

import (
	"strings"
	"testing"
	"time"
)

func TestWindowRanges(t *testing.T) {
	now := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
	day := 24 * time.Hour

	cases := []struct {
		kind   Kind
		lo, hi time.Time
	}{
		{KindExpiringSoon, now, now.Add(day)},
		{KindExpiredRecent, now.Add(-day), now},
		{KindExpiredWinback, now.Add(-8 * day), now.Add(-7 * day)},
	}
	for _, c := range cases {
		lo, hi, ok := Window(c.kind, now)
		if !ok {
			t.Fatalf("%s: ok=false", c.kind)
		}
		if !lo.Equal(c.lo) || !hi.Equal(c.hi) {
			t.Errorf("%s: got [%v,%v) want [%v,%v)", c.kind, lo, hi, c.lo, c.hi)
		}
		if !lo.Before(hi) {
			t.Errorf("%s: lo not before hi", c.kind)
		}
	}

	if _, _, ok := Window(Kind("bogus"), now); ok {
		t.Error("unknown kind should return ok=false")
	}
}

// A fresh 3-day trial registered at `now` must NOT land in the expiring_soon
// window — that window is the next 24h, the trial expires in 72h. (This is why
// the window is 24h not 72h.)
func TestExpiringWindowExcludesFreshTrial(t *testing.T) {
	now := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
	lo, hi, _ := Window(KindExpiringSoon, now)
	freshTrialExpiry := now.Add(72 * time.Hour)
	if !freshTrialExpiry.Before(lo) && freshTrialExpiry.Before(hi) {
		t.Errorf("fresh 3-day trial expiry %v should be outside [%v,%v)", freshTrialExpiry, lo, hi)
	}
}

func TestComposeAllVariantsNonEmpty(t *testing.T) {
	for _, kind := range AllKinds {
		for _, paid := range []bool{true, false} {
			for _, lang := range []string{"ru", "en"} {
				n := Compose(kind, paid, lang, "https://madfrog.online/app")
				if n.PushTitle == "" || n.PushBody == "" {
					t.Errorf("%s paid=%v %s: empty push", kind, paid, lang)
				}
				if n.EmailSubject == "" || n.EmailHTML == "" || n.EmailText == "" {
					t.Errorf("%s paid=%v %s: empty email", kind, paid, lang)
				}
				if !strings.Contains(n.EmailHTML, "https://madfrog.online/app") {
					t.Errorf("%s paid=%v %s: CTA url missing from email", kind, paid, lang)
				}
			}
		}
	}
}

func TestComposePaidVsTrialFraming(t *testing.T) {
	paid := Compose(KindExpiredRecent, true, "en", "")
	trial := Compose(KindExpiredRecent, false, "en", "")
	if !strings.Contains(strings.ToLower(paid.EmailHTML), "subscription") {
		t.Error("paid copy should mention subscription")
	}
	if !strings.Contains(strings.ToLower(trial.EmailHTML), "trial") {
		t.Error("trial copy should mention trial")
	}
}

func TestComposeLangSelection(t *testing.T) {
	ru := Compose(KindExpiringSoon, true, "ru", "")
	en := Compose(KindExpiringSoon, true, "en", "")
	if ru.EmailSubject == en.EmailSubject {
		t.Error("ru and en subjects should differ")
	}
	// default (unknown) → RU
	def := Compose(KindExpiringSoon, true, "", "")
	if def.EmailSubject != ru.EmailSubject {
		t.Errorf("empty lang should default to RU: got %q want %q", def.EmailSubject, ru.EmailSubject)
	}
}
