package freekassa

import "testing"

// IPAllowed is the anti-spoof gate on the FreeKassa webhook: only the configured
// notification source IPs may credit a subscription. Empty allowlist = allow-all
// (dev only). It must strip an optional ":port" before matching.
func TestIPAllowed(t *testing.T) {
	allow := []string{"1.2.3.4", "5.6.7.8"}
	tests := []struct {
		name      string
		addr      string
		allowlist []string
		want      bool
	}{
		{"empty allowlist allows all", "9.9.9.9:1234", nil, true},
		{"host with port, in list", "1.2.3.4:54321", allow, true},
		{"bare host, in list", "5.6.7.8", allow, true},
		{"host with port, not in list", "9.9.9.9:80", allow, false},
		{"bare host, not in list", "9.9.9.9", allow, false},
		{"ipv6 with port, in list", "[::1]:443", []string{"::1"}, true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := IPAllowed(tc.addr, tc.allowlist); got != tc.want {
				t.Errorf("IPAllowed(%q, %v) = %v, want %v", tc.addr, tc.allowlist, got, tc.want)
			}
		})
	}
}
