// attachment_test.go covers the pure attachment helpers (validation, filename
// sanitization, key building/ownership). No B2 / network — runs in the normal
// (non-integration) test pass.
package storage

import (
	"strings"
	"testing"
)

func TestSanitizeFilename(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"photo.jpg", "photo.jpg"},
		{"my report-2.pdf", "my_report-2.pdf"},
		{"скрин.png", "_____.png"},       // 5 cyrillic runes → 5 underscores
		{"  outer spaces  ", "outer_spaces"}, // TrimSpace strips ends; inner space → _
		{"a/b\\c", "a_b_c"},
		{"", "file"},
		{"///", "file"}, // every rune replaced by '_', then Trim("___", "._-")="" → fallback
		{"...", "file"}, // dots kept but Trim("...", "._-")="" → fallback
		{"under_score", "under_score"},
	}
	for _, c := range cases {
		if got := SanitizeFilename(c.in); got != c.want {
			t.Errorf("SanitizeFilename(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestSanitizeFilenameKeepsAllowedRunes(t *testing.T) {
	got := SanitizeFilename("Aa9._-")
	if got != "Aa9._-" {
		t.Errorf("allowed runes mangled: %q", got)
	}
}

func TestMIMEAllowed(t *testing.T) {
	for _, m := range []string{"image/jpeg", "image/png", "image/heic", "image/webp", "image/gif", "application/pdf", "text/plain"} {
		if !MIMEAllowed(m) {
			t.Errorf("MIMEAllowed(%q) = false, want true", m)
		}
	}
	for _, m := range []string{"application/x-msdownload", "image/svg+xml", "", "text/html"} {
		if MIMEAllowed(m) {
			t.Errorf("MIMEAllowed(%q) = true, want false", m)
		}
	}
}

func TestSizeAllowed(t *testing.T) {
	cases := []struct {
		size int64
		want bool
	}{
		{0, false},
		{-1, false},
		{1, true},
		{MaxAttachmentSize, true},
		{MaxAttachmentSize + 1, false},
	}
	for _, c := range cases {
		if got := SizeAllowed(c.size); got != c.want {
			t.Errorf("SizeAllowed(%d) = %v, want %v", c.size, got, c.want)
		}
	}
}

func TestBuildKeyAndOwnership(t *testing.T) {
	key := BuildKey(42, "shot.png")
	if !strings.HasPrefix(key, "support/42/") {
		t.Fatalf("key %q missing support/42/ prefix", key)
	}
	if !strings.HasSuffix(key, "/shot.png") {
		t.Errorf("key %q missing sanitized filename suffix", key)
	}
	// uuid segment makes two keys for the same thread+name distinct.
	if k2 := BuildKey(42, "shot.png"); k2 == key {
		t.Errorf("BuildKey not unique: %q == %q", key, k2)
	}

	if !KeyBelongsToThread(key, 42) {
		t.Errorf("KeyBelongsToThread(own thread) = false")
	}
	if KeyBelongsToThread(key, 7) {
		t.Errorf("KeyBelongsToThread(other thread) = true — authz hole")
	}
	// Prefix-confusion guard: support/42 must not match support/420.
	if KeyBelongsToThread("support/420/x/y.png", 42) {
		t.Errorf("support/420 wrongly matched thread 42")
	}
}
