// nodes_test.go — pure-helper unit test for the admin protocols list.
// Regression guard for 2026-06-06 ("протоколы не все"): ListProtocols was
// hardcoded to VLESS-only, hiding the live Hysteria2 fallback.
package admin

import "testing"

func TestVPNProtocols(t *testing.T) {
	find := func(ps []protocolInfo, name string) protocolInfo {
		for _, p := range ps {
			if p.Name == name {
				return p
			}
		}
		t.Fatalf("protocol %q not present", name)
		return protocolInfo{}
	}

	t.Run("NL prod shape: VLESS + Hysteria2 on, TUIC off", func(t *testing.T) {
		ps := vpnProtocols(443, 443, 0, "/etc/singbox/server.crt")
		if len(ps) != 3 {
			t.Fatalf("want 3 protocols, got %d", len(ps))
		}
		if !find(ps, "vless-reality-tcp").Enabled {
			t.Error("VLESS must always be enabled")
		}
		if !find(ps, "hysteria2").Enabled {
			t.Error("Hysteria2 must be enabled when port>0 and a UDP cert is set")
		}
		if find(ps, "tuic").Enabled {
			t.Error("TUIC must be disabled when its port is 0")
		}
	})

	t.Run("no UDP cert => H2/TUIC disabled even with ports set", func(t *testing.T) {
		ps := vpnProtocols(443, 443, 8443, "")
		if find(ps, "hysteria2").Enabled || find(ps, "tuic").Enabled {
			t.Error("UDP protocols must be disabled without a pinnable cert")
		}
		if !find(ps, "vless-reality-tcp").Enabled {
			t.Error("VLESS stays enabled regardless")
		}
	})

	t.Run("both UDP ports + cert => all on", func(t *testing.T) {
		ps := vpnProtocols(443, 443, 8443, "/etc/singbox/server.crt")
		if !find(ps, "hysteria2").Enabled || !find(ps, "tuic").Enabled {
			t.Error("both UDP protocols should be enabled")
		}
	})
}
