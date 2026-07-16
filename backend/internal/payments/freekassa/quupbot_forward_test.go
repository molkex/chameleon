package freekassa

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

func TestIsQuupbotPayment(t *testing.T) {
	cases := map[string]bool{
		"qb_1":   true,
		"qb_142": true,
		"app_1":  false,
		"qb":     false,
		"":       false,
		"QB_1":   false, // case-sensitive: FreeKassa echoes our own order id verbatim
		"xqb_1":  false, // must be a prefix, not a substring
	}
	for id, want := range cases {
		if got := IsQuupbotPayment(id); got != want {
			t.Errorf("IsQuupbotPayment(%q) = %v, want %v", id, got, want)
		}
	}
}

func TestNewQuupbotForwarder_NilWhenUnconfigured(t *testing.T) {
	if f := NewQuupbotForwarder("", "secret"); f != nil {
		t.Error("expected nil forwarder with empty URL")
	}
	if f := NewQuupbotForwarder("https://example.com", ""); f != nil {
		t.Error("expected nil forwarder with empty secret")
	}
	if f := NewQuupbotForwarder("https://example.com", "secret"); f == nil {
		t.Error("expected non-nil forwarder when both URL and secret are set")
	}
}

func TestQuupbotForward_SendsSignedBody(t *testing.T) {
	const secret = "shared-secret"
	var gotBody, gotTS, gotSig, gotMethod, gotContentType string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		gotContentType = r.Header.Get("Content-Type")
		gotTS = r.Header.Get("X-Forward-Timestamp")
		gotSig = r.Header.Get("X-Forward-Signature")
		buf, _ := io.ReadAll(r.Body)
		gotBody = string(buf)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	f := NewQuupbotForwarder(srv.URL, secret)
	form := url.Values{"MERCHANT_ORDER_ID": {"qb_1"}, "AMOUNT": {"999.00"}}

	if err := f.Forward(context.Background(), form); err != nil {
		t.Fatalf("Forward: %v", err)
	}

	if gotMethod != http.MethodPost {
		t.Errorf("method = %q, want POST", gotMethod)
	}
	if gotContentType != "application/x-www-form-urlencoded" {
		t.Errorf("content-type = %q", gotContentType)
	}
	if gotBody != form.Encode() {
		t.Errorf("body = %q, want %q", gotBody, form.Encode())
	}

	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(gotTS))
	mac.Write([]byte("\n"))
	mac.Write([]byte(gotBody))
	wantSig := hex.EncodeToString(mac.Sum(nil))
	if gotSig != wantSig {
		t.Errorf("signature = %q, want %q", gotSig, wantSig)
	}
}

func TestQuupbotForward_ResponseMapping(t *testing.T) {
	cases := []struct {
		name       string
		status     int
		closeEarly bool
		wantErr    bool
		wantReject bool
	}{
		{name: "200 ok", status: http.StatusOK, wantErr: false},
		{name: "404 permanent", status: http.StatusNotFound, wantErr: true, wantReject: true},
		{name: "403 permanent", status: http.StatusForbidden, wantErr: true, wantReject: true},
		{name: "409 permanent", status: http.StatusConflict, wantErr: true, wantReject: true},
		{name: "500 transient", status: http.StatusInternalServerError, wantErr: true, wantReject: false},
		{name: "502 transient", status: http.StatusBadGateway, wantErr: true, wantReject: false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tc.status)
			}))
			defer srv.Close()

			f := NewQuupbotForwarder(srv.URL, "secret")
			err := f.Forward(context.Background(), url.Values{"a": {"b"}})

			if (err != nil) != tc.wantErr {
				t.Fatalf("Forward error = %v, wantErr %v", err, tc.wantErr)
			}
			if tc.wantReject && err != nil && !errors.Is(err, ErrForwardRejected) {
				t.Errorf("expected ErrForwardRejected, got %v", err)
			}
			if !tc.wantReject && err != nil && errors.Is(err, ErrForwardRejected) {
				t.Errorf("expected transient error, got ErrForwardRejected: %v", err)
			}
		})
	}
}

func TestQuupbotForward_ServerUnreachable(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	srv.Close() // closed before any request — connection refused

	f := NewQuupbotForwarder(srv.URL, "secret")
	err := f.Forward(context.Background(), url.Values{"a": {"b"}})
	if err == nil {
		t.Fatal("expected error for unreachable server")
	}
	if errors.Is(err, ErrForwardRejected) {
		t.Error("connection failure must be treated as transient, not ErrForwardRejected")
	}
}
