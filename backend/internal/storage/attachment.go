package storage

import (
	"os"
	"strconv"
	"strings"

	"github.com/google/uuid"
)

const (
	// MaxAttachmentSize bounds a single upload (10 MiB). Large enough for a
	// screenshot or a short PDF, small enough to keep B2 egress + presign abuse
	// in check.
	MaxAttachmentSize int64 = 10 * 1024 * 1024

	// keyPrefix namespaces all support attachments inside the shared bucket so
	// they never collide with backups (the bucket's primary tenant).
	keyPrefix = "support/"
)

// allowedMIME is the upload allowlist — images, PDF, and plain text. Anything
// else is rejected before a presigned URL is ever issued.
var allowedMIME = map[string]bool{
	"image/jpeg":      true,
	"image/png":       true,
	"image/heic":      true,
	"image/webp":      true,
	"image/gif":       true,
	"application/pdf": true,
	"text/plain":      true,
}

// MIMEAllowed reports whether mime is in the upload allowlist. Pure.
func MIMEAllowed(mime string) bool {
	return allowedMIME[mime]
}

// SizeAllowed reports whether size is within (0, MaxAttachmentSize]. Pure.
func SizeAllowed(size int64) bool {
	return size > 0 && size <= MaxAttachmentSize
}

// SanitizeFilename keeps [A-Za-z0-9._-] and replaces every other rune with '_'.
// Empty / all-stripped input falls back to "file". Pure (unit-tested).
func SanitizeFilename(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return "file"
	}
	var b strings.Builder
	b.Grow(len(name))
	for _, r := range name {
		switch {
		case r >= 'a' && r <= 'z',
			r >= 'A' && r <= 'Z',
			r >= '0' && r <= '9',
			r == '.', r == '-', r == '_':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	out := b.String()
	if strings.Trim(out, "._-") == "" {
		return "file"
	}
	return out
}

// BuildKey returns the object key for a thread's attachment:
// support/<threadID>/<uuid>/<sanitized-filename>. The uuid segment prevents
// collisions and makes a leaked presigned PUT URL unguessable for siblings.
func BuildKey(threadID int64, filename string) string {
	return keyPrefix + strconv.FormatInt(threadID, 10) + "/" + uuid.NewString() + "/" + SanitizeFilename(filename)
}

// KeyBelongsToThread guards authz on send: a client-supplied attachment key must
// live under this thread's prefix, so a user can't claim another thread's
// upload. Pure (unit-tested).
func KeyBelongsToThread(key string, threadID int64) bool {
	return strings.HasPrefix(key, keyPrefix+strconv.FormatInt(threadID, 10)+"/")
}

// NewFromEnv builds a Client from the B2 environment (B2_KEY_ID,
// B2_APPLICATION_KEY, B2_BUCKET, B2_ENDPOINT, B2_REGION). It returns (nil, nil)
// when any required var is unset — the caller treats that as "attachments
// gracefully disabled" rather than an error.
func NewFromEnv() (*Client, error) {
	keyID := os.Getenv("B2_KEY_ID")
	appKey := os.Getenv("B2_APPLICATION_KEY")
	bucket := os.Getenv("B2_BUCKET")
	endpoint := os.Getenv("B2_ENDPOINT")
	if keyID == "" || appKey == "" || bucket == "" || endpoint == "" {
		return nil, nil
	}
	return New(endpoint, os.Getenv("B2_REGION"), keyID, appKey, bucket)
}
