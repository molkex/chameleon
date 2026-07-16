package mobile

import "testing"

// TestParseClientBuild pins the trust boundary on the X-App-Build header —
// it feeds directly into vpn.generateClientConfig's leanMode gate
// (STALL-ON-NETSWITCH-LEAN-FIX, 2026-07-16), so anything that isn't a clean
// non-negative build number must resolve to 0 (the safe "treat as
// old/unknown client, stay lean" default) rather than error or panic.
func TestParseClientBuild(t *testing.T) {
	cases := map[string]int{
		"137":       137,
		"  138  ":   138,
		"0":         0,
		"":          0,
		"-1":        0,
		"not-a-int": 0,
		"137.5":     0,
		"<script>":  0,
	}
	for in, want := range cases {
		if got := parseClientBuild(in); got != want {
			t.Errorf("parseClientBuild(%q) = %d, want %d", in, got, want)
		}
	}
}
