package vpn

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// UserAPIClient drives the sing-box fork's User API — the zero-downtime user
// provisioning path (also the mechanism RelayUserSyncer uses to push users to
// remote exits). These tests mock that API with httptest and assert the wire
// contract: HTTP method, path, bearer auth, and JSON body for each operation.

type capturedReq struct {
	method  string
	path    string
	escaped string // r.URL.EscapedPath() — proves path-escaping of the username
	auth    string
	ctype   string
	body    []byte
}

func newUserAPITestServer(t *testing.T, code int, respBody string, cap *capturedReq) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		*cap = capturedReq{
			method:  r.Method,
			path:    r.URL.Path,
			escaped: r.URL.EscapedPath(),
			auth:    r.Header.Get("Authorization"),
			ctype:   r.Header.Get("Content-Type"),
			body:    b,
		}
		w.WriteHeader(code)
		_, _ = w.Write([]byte(respBody))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestUserAPIAddUser(t *testing.T) {
	var cap capturedReq
	srv := newUserAPITestServer(t, http.StatusCreated, "", &cap)
	c := NewUserAPIClientFromURL(srv.URL, "sek", "vless-in")

	if err := c.AddUser(context.Background(), VPNUser{Username: "u1", UUID: "uuid-1"}); err != nil {
		t.Fatalf("AddUser: %v", err)
	}
	if cap.method != http.MethodPost {
		t.Errorf("method = %s, want POST", cap.method)
	}
	if cap.path != "/api/v1/inbounds/vless-in/users" {
		t.Errorf("path = %s", cap.path)
	}
	if cap.auth != "Bearer sek" {
		t.Errorf("auth = %q, want %q", cap.auth, "Bearer sek")
	}
	if cap.ctype != "application/json" {
		t.Errorf("content-type = %q", cap.ctype)
	}
	var got map[string]any
	if err := json.Unmarshal(cap.body, &got); err != nil {
		t.Fatalf("unmarshal body: %v", err)
	}
	if got["name"] != "u1" || got["uuid"] != "uuid-1" || got["flow"] != "xtls-rprx-vision" {
		t.Errorf("body = %v, want name=u1 uuid=uuid-1 flow=xtls-rprx-vision", got)
	}
}

func TestUserAPIAddUserError(t *testing.T) {
	var cap capturedReq
	srv := newUserAPITestServer(t, http.StatusConflict, "already exists", &cap)
	c := NewUserAPIClientFromURL(srv.URL, "sek", "vless-in")

	err := c.AddUser(context.Background(), VPNUser{Username: "u1", UUID: "x"})
	if err == nil || !strings.Contains(err.Error(), "already exists") || !strings.Contains(err.Error(), "409") {
		t.Fatalf("want 409 error carrying the body, got %v", err)
	}
}

func TestUserAPIRemoveUser(t *testing.T) {
	var cap capturedReq
	srv := newUserAPITestServer(t, http.StatusOK, "", &cap)
	c := NewUserAPIClientFromURL(srv.URL, "sek", "vless-in")

	if err := c.RemoveUser(context.Background(), "user with space"); err != nil {
		t.Fatalf("RemoveUser: %v", err)
	}
	if cap.method != http.MethodDelete {
		t.Errorf("method = %s, want DELETE", cap.method)
	}
	if cap.path != "/api/v1/inbounds/vless-in/users/user with space" {
		t.Errorf("decoded path = %q", cap.path)
	}
	if !strings.Contains(cap.escaped, "user%20with%20space") {
		t.Errorf("escaped path = %q, want the username percent-escaped", cap.escaped)
	}
}

func TestUserAPIReplaceUsers(t *testing.T) {
	var cap capturedReq
	srv := newUserAPITestServer(t, http.StatusOK, "", &cap)
	c := NewUserAPIClientFromURL(srv.URL, "sek", "vless-in")

	users := []VPNUser{{Username: "a", UUID: "ua"}, {Username: "b", UUID: "ub"}}
	if err := c.ReplaceUsers(context.Background(), users); err != nil {
		t.Fatalf("ReplaceUsers: %v", err)
	}
	if cap.method != http.MethodPut {
		t.Errorf("method = %s, want PUT", cap.method)
	}
	var got struct {
		Users []map[string]any `json:"users"`
	}
	if err := json.Unmarshal(cap.body, &got); err != nil {
		t.Fatalf("unmarshal body: %v", err)
	}
	if len(got.Users) != 2 || got.Users[0]["name"] != "a" || got.Users[1]["flow"] != "xtls-rprx-vision" {
		t.Errorf("users = %v", got.Users)
	}
}

// ReplaceUsers with no users must send `"users":[]` (clear all), never null.
func TestUserAPIReplaceUsersEmptyIsArray(t *testing.T) {
	var cap capturedReq
	srv := newUserAPITestServer(t, http.StatusOK, "", &cap)
	c := NewUserAPIClientFromURL(srv.URL, "sek", "vless-in")

	if err := c.ReplaceUsers(context.Background(), nil); err != nil {
		t.Fatalf("ReplaceUsers(nil): %v", err)
	}
	if !strings.Contains(string(cap.body), `"users":[]`) {
		t.Errorf("empty replace body = %s, want users:[]", cap.body)
	}
}

func TestUserAPIHealth(t *testing.T) {
	var cap capturedReq
	srv := newUserAPITestServer(t, http.StatusOK, "", &cap)
	c := NewUserAPIClientFromURL(srv.URL, "sek", "vless-in")

	if err := c.Health(context.Background()); err != nil {
		t.Fatalf("Health: %v", err)
	}
	if cap.method != http.MethodGet || cap.path != "/api/v1/inbounds" {
		t.Errorf("method=%s path=%s, want GET /api/v1/inbounds", cap.method, cap.path)
	}
}

func TestUserAPIHealthDown(t *testing.T) {
	var cap capturedReq
	srv := newUserAPITestServer(t, http.StatusInternalServerError, "", &cap)
	c := NewUserAPIClientFromURL(srv.URL, "sek", "vless-in")

	if err := c.Health(context.Background()); err == nil || !strings.Contains(err.Error(), "500") {
		t.Fatalf("want 500 health error, got %v", err)
	}
}

func TestUserAPINoAuthHeaderWhenSecretEmpty(t *testing.T) {
	var cap capturedReq
	srv := newUserAPITestServer(t, http.StatusCreated, "", &cap)
	c := NewUserAPIClientFromURL(srv.URL, "", "vless-in")

	_ = c.AddUser(context.Background(), VPNUser{Username: "u", UUID: "x"})
	if cap.auth != "" {
		t.Errorf("expected no Authorization header for empty secret, got %q", cap.auth)
	}
}

func TestUserAPIRequestFailure(t *testing.T) {
	// Port 1 → connection refused immediately.
	c := NewUserAPIClientFromURL("http://127.0.0.1:1", "sek", "vless-in")
	err := c.AddUser(context.Background(), VPNUser{Username: "u", UUID: "x"})
	if err == nil || !strings.Contains(err.Error(), "request failed") {
		t.Fatalf("want request-failed error, got %v", err)
	}
}
