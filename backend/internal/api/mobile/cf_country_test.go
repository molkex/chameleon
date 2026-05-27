package mobile

import "testing"

// TestCFCountryCode pins the trust boundary on the CF-IPCountry header —
// we want a 2-letter ISO code or nothing, never a sentinel like "XX" / "T1"
// (CF's "couldn't resolve" / "Tor exit") leaking into users.last_country
// where downstream UI would render it as a broken flag emoji.
func TestCFCountryCode(t *testing.T) {
	cases := map[string]string{
		"RU":       "RU",
		"us":       "US", // CF sends uppercase, but normalise for safety
		"  DE  ":   "DE",
		"":         "",
		"XX":       "", // CF: anonymous proxy / non-country IP
		"T1":       "", // CF: Tor exit
		"USA":      "", // wrong length — refuse rather than truncate
		"R":        "",
		"<script>": "",
	}
	for in, want := range cases {
		if got := cfCountryCode(in); got != want {
			t.Errorf("cfCountryCode(%q) = %q, want %q", in, got, want)
		}
	}
}
