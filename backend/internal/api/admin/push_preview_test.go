// push_preview_test.go — pure-helper unit test for the agent-reply push
// preview (truncation + attachment-only fallback). No DB / APNs needed.
package admin

import (
	"strings"
	"testing"
)

func TestPushPreview(t *testing.T) {
	t.Run("short body passes through", func(t *testing.T) {
		if got := pushPreview("  привет  ", false); got != "привет" {
			t.Errorf("pushPreview = %q, want %q", got, "привет")
		}
	})

	t.Run("attachment-only", func(t *testing.T) {
		if got := pushPreview("", true); got != "Вложение" {
			t.Errorf("pushPreview = %q, want Вложение", got)
		}
	})

	t.Run("empty + no attachment", func(t *testing.T) {
		if got := pushPreview("   ", false); got != "" {
			t.Errorf("pushPreview = %q, want empty", got)
		}
	})

	t.Run("truncates long body on a rune boundary", func(t *testing.T) {
		// 200 cyrillic runes (multibyte) — must cut to pushPreviewLen runes + …,
		// never split a multibyte char.
		long := strings.Repeat("я", 200)
		got := pushPreview(long, false)
		runes := []rune(got)
		if len(runes) != pushPreviewLen+1 { // +1 for the ellipsis
			t.Errorf("truncated len = %d runes, want %d", len(runes), pushPreviewLen+1)
		}
		if runes[len(runes)-1] != '…' {
			t.Errorf("expected trailing ellipsis, got %q", string(runes[len(runes)-1]))
		}
	})
}
