package mobile

import "testing"

func TestAnnouncementMatches(t *testing.T) {
	cases := []struct {
		name                                  string
		audience, platform, userSub, userPlat string
		want                                  bool
	}{
		{"all/all reaches anyone", "all", "all", "trial", "ios", true},
		{"all/all reaches an unknown user", "all", "all", "", "", true},
		{"trial reaches trial", "trial", "all", "trial", "ios", true},
		{"trial blocks paid", "trial", "all", "paid", "ios", false},
		{"paid reaches paid", "paid", "all", "paid", "macos", true},
		{"expired reaches expired", "expired", "all", "expired", "ios", true},
		{"ios reaches ios", "all", "ios", "trial", "ios", true},
		{"ios blocks macos", "all", "ios", "trial", "macos", false},
		{"macos reaches macos", "all", "macos", "paid", "macos", true},
		{"both filters must match", "paid", "ios", "paid", "ios", true},
		{"both filters — one fails", "paid", "ios", "paid", "macos", false},
		{"audience-targeted blocks an unknown user", "trial", "all", "", "", false},
		{"platform-targeted blocks an unknown platform", "all", "ios", "trial", "", false},
	}
	for _, c := range cases {
		if got := announcementMatches(c.audience, c.platform, c.userSub, c.userPlat); got != c.want {
			t.Errorf("%s: announcementMatches(%q,%q,%q,%q)=%v want %v",
				c.name, c.audience, c.platform, c.userSub, c.userPlat, got, c.want)
		}
	}
}

func TestPlatformFromOS(t *testing.T) {
	cases := map[string]string{
		"iOS":      "ios",
		"iPadOS":   "ios",
		"macOS":    "macos",
		"Mac OS X": "macos",
		"":         "",
	}
	for in, want := range cases {
		if got := platformFromOS(in); got != want {
			t.Errorf("platformFromOS(%q)=%q want %q", in, got, want)
		}
	}
}
