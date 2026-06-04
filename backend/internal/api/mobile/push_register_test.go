// push_register_test.go — pure-helper unit tests for the push-register
// endpoint's token validation (no DB / HTTP needed).
package mobile

import "testing"

func TestIsHexToken(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"", false},
		{"deadbeef", true},
		{"DEADBEEF", true},
		{"abcdef0123456789", true},
		{"abcg", false},      // 'g' is not hex
		{"12 34", false},     // space
		{"12:34", false},     // separator
		{"абвг", false},      // cyrillic
		{"0000000000000000000000000000000000000000000000000000000000000000", true},
	}
	for _, c := range cases {
		if got := isHexToken(c.in); got != c.want {
			t.Errorf("isHexToken(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}
