package mobile

import (
	"strings"
	"testing"
)

func TestChatCapForTier(t *testing.T) {
	if got := chatCapForTier(false); got != chatRateAuthedPerMin {
		t.Errorf("authed cap = %d, want %d", got, chatRateAuthedPerMin)
	}
	if got := chatCapForTier(true); got != chatRateAnonPerMin {
		t.Errorf("anon cap = %d, want %d", got, chatRateAnonPerMin)
	}
	if chatCapForTier(true) >= chatCapForTier(false) {
		t.Error("anon tier must be strictly tighter than authed")
	}
}

func TestNormalizeChatBody(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
		ok   bool
	}{
		{"trims surrounding whitespace", "  hi  ", "hi", true},
		{"blank is invalid", "   \n\t ", "", false},
		{"empty is invalid", "", "", false},
		{"at max length is valid", strings.Repeat("y", maxChatBodyLen), strings.Repeat("y", maxChatBodyLen), true},
		{"over max length is invalid", strings.Repeat("x", maxChatBodyLen+1), "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := normalizeChatBody(tc.in)
			if ok != tc.ok || got != tc.want {
				t.Errorf("normalizeChatBody(%q) = (%q, %v), want (%q, %v)", tc.in, got, ok, tc.want, tc.ok)
			}
		})
	}
}
