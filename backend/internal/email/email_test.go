package email

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"

	"go.uber.org/zap"
)

// roundTripperFunc stands in for the network so ResendSender.Send is
// tested without touching api.resend.com.
type roundTripperFunc func(*http.Request) (*http.Response, error)

func (f roundTripperFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func stubResponse(status int, body string) (*http.Response, error) {
	return &http.Response{
		StatusCode: status,
		Body:       io.NopCloser(strings.NewReader(body)),
		Header:     make(http.Header),
	}, nil
}

// ─── NewResendSender: construction / validation ────────────────────────────

func TestNewResendSender_Validation(t *testing.T) {
	log := zap.NewNop()
	if s := NewResendSender("", "info@madfrog.online", "MadFrog", log); s != nil {
		t.Error("empty apiKey should yield nil sender")
	}
	if s := NewResendSender("re_key", "", "MadFrog", log); s != nil {
		t.Error("empty fromEmail should yield nil sender")
	}
	if s := NewResendSender("re_key", "info@madfrog.online", "MadFrog", log); s == nil {
		t.Fatal("valid args should yield a sender")
	}
}

func TestNewResendSender_FromAddrFormatting(t *testing.T) {
	log := zap.NewNop()
	withName := NewResendSender("re_key", "info@madfrog.online", "MadFrog VPN", log)
	if withName.fromAddr != "MadFrog VPN <info@madfrog.online>" {
		t.Errorf("fromAddr = %q, want display-name form", withName.fromAddr)
	}
	noName := NewResendSender("re_key", "info@madfrog.online", "", log)
	if noName.fromAddr != "info@madfrog.online" {
		t.Errorf("fromAddr = %q, want bare email", noName.fromAddr)
	}
}

// ─── ResendSender.Send ─────────────────────────────────────────────────────

func newStubSender(t *testing.T, rt roundTripperFunc) *ResendSender {
	t.Helper()
	s := NewResendSender("re_test_key", "info@madfrog.online", "MadFrog VPN", zap.NewNop())
	s.http = &http.Client{Transport: rt}
	return s
}

func TestResendSend_Success(t *testing.T) {
	s := newStubSender(t, func(*http.Request) (*http.Response, error) {
		return stubResponse(http.StatusOK, `{"id":"abc-123"}`)
	})
	err := s.Send(context.Background(), Message{
		To: "user@example.com", Subject: "Hi", HTMLBody: "<b>hi</b>", TextBody: "hi",
	})
	if err != nil {
		t.Errorf("Send on 200 should succeed, got %v", err)
	}
}

func TestResendSend_RequestShape(t *testing.T) {
	var gotURL, gotAuth, gotCT string
	var gotBody resendRequest
	s := newStubSender(t, func(req *http.Request) (*http.Response, error) {
		gotURL = req.URL.String()
		gotAuth = req.Header.Get("Authorization")
		gotCT = req.Header.Get("Content-Type")
		_ = json.NewDecoder(req.Body).Decode(&gotBody)
		return stubResponse(http.StatusOK, `{"id":"x"}`)
	})
	_ = s.Send(context.Background(), Message{
		To: "user@example.com", Subject: "Subj", HTMLBody: "<p>h</p>", TextBody: "h",
	})
	if gotURL != "https://api.resend.com/emails" {
		t.Errorf("URL = %q, want the Resend emails endpoint", gotURL)
	}
	if gotAuth != "Bearer re_test_key" {
		t.Errorf("Authorization = %q, want bearer token", gotAuth)
	}
	if gotCT != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", gotCT)
	}
	if len(gotBody.To) != 1 || gotBody.To[0] != "user@example.com" {
		t.Errorf("body.To = %v, want [user@example.com]", gotBody.To)
	}
	if gotBody.From != "MadFrog VPN <info@madfrog.online>" {
		t.Errorf("body.From = %q", gotBody.From)
	}
	if gotBody.Subject != "Subj" || gotBody.HTML != "<p>h</p>" || gotBody.Text != "h" {
		t.Errorf("body content not carried through: %+v", gotBody)
	}
}

func TestResendSend_RejectsErrorStatus(t *testing.T) {
	for _, status := range []int{http.StatusBadRequest, http.StatusUnauthorized, http.StatusInternalServerError} {
		s := newStubSender(t, func(*http.Request) (*http.Response, error) {
			return stubResponse(status, `{"message":"nope"}`)
		})
		err := s.Send(context.Background(), Message{To: "u@e.com", Subject: "s"})
		if err == nil {
			t.Errorf("Send on %d should error", status)
		}
	}
}

func TestResendSend_TransportError(t *testing.T) {
	s := newStubSender(t, func(*http.Request) (*http.Response, error) {
		return nil, errors.New("dial tcp: connection refused")
	})
	if err := s.Send(context.Background(), Message{To: "u@e.com", Subject: "s"}); err == nil {
		t.Error("Send should propagate a transport error")
	}
}

// ─── NoopSender + sentinel ─────────────────────────────────────────────────

func TestNoopSender_AlwaysSucceeds(t *testing.T) {
	s := NewNoopSender(zap.NewNop())
	if err := s.Send(context.Background(), Message{To: "u@e.com", Subject: "s"}); err != nil {
		t.Errorf("NoopSender.Send should never error, got %v", err)
	}
	// NoopSender must satisfy the Sender interface.
	var _ Sender = s
	var _ Sender = (*ResendSender)(nil)
}

func TestErrNotConfigured_IsSentinel(t *testing.T) {
	if !errors.Is(ErrNotConfigured, ErrNotConfigured) {
		t.Error("ErrNotConfigured should be its own sentinel")
	}
	if ErrNotConfigured.Error() == "" {
		t.Error("ErrNotConfigured must have a message")
	}
}
