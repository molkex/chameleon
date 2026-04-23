// Package email sends transactional mail. Currently backed by Resend
// (resend.com), with a noop fallback used in tests and when credentials
// are absent.
package email

import (
	"context"
	"errors"
)

// Message is a single transactional email.
type Message struct {
	To       string
	Subject  string
	HTMLBody string
	TextBody string
}

// Sender sends Message. Implementations must be safe for concurrent use.
type Sender interface {
	Send(ctx context.Context, msg Message) error
}

// ErrNotConfigured is returned by Send() when no provider is configured.
// Handlers treat this as a non-fatal warning so dev environments without
// SMTP credentials don't break the auth flow.
var ErrNotConfigured = errors.New("email: no provider configured")
