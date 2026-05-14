package useragent

import "testing"

func TestParse(t *testing.T) {
	cases := []struct {
		name string
		ua   string
		want Parsed
	}{
		{
			name: "full Chameleon UA",
			ua:   "Chameleon/16 CFNetwork/3860.200.71 Darwin/25.1.0",
			want: Parsed{AppVersion: "16", OSName: "iOS", OSVersion: "25.1.0"},
		},
		{
			name: "app token only",
			ua:   "Chameleon/71",
			want: Parsed{AppVersion: "71"},
		},
		{
			name: "darwin token only",
			ua:   "CFNetwork/1.0 Darwin/24.0.0",
			want: Parsed{OSName: "iOS", OSVersion: "24.0.0"},
		},
		{
			name: "old darwin → no OS name",
			ua:   "Chameleon/10 Darwin/19.6.0",
			want: Parsed{AppVersion: "10", OSName: "", OSVersion: "19.6.0"},
		},
		{
			name: "empty",
			ua:   "",
			want: Parsed{},
		},
		{
			name: "unrelated UA",
			ua:   "Mozilla/5.0 (compatible; Googlebot/2.1)",
			want: Parsed{},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := Parse(c.ua); got != c.want {
				t.Errorf("Parse(%q) = %+v, want %+v", c.ua, got, c.want)
			}
		})
	}
}

func TestMajorVersion(t *testing.T) {
	cases := []struct {
		in   string
		want int
	}{
		{"25.1.0", 25},
		{"24.0.0", 24},
		{"20", 20},
		{"9.8.7", 9},
		{"", 0},
		{"not-a-version", 0},
	}
	for _, c := range cases {
		if got := majorVersion(c.in); got != c.want {
			t.Errorf("majorVersion(%q) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestDarwinToOSName(t *testing.T) {
	// Darwin 20 = macOS 11 / iOS 14 — the cutoff the heuristic uses.
	cases := []struct {
		ver  string
		want string
	}{
		{"25.1.0", "iOS"},
		{"24.0.0", "iOS"},
		{"20.0.0", "iOS"},
		{"19.6.0", ""},
		{"0", ""},
		{"", ""},
	}
	for _, c := range cases {
		if got := darwinToOSName(c.ver); got != c.want {
			t.Errorf("darwinToOSName(%q) = %q, want %q", c.ver, got, c.want)
		}
	}
}
