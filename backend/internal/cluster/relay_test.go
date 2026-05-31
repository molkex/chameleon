package cluster

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/db"
)

// fakeRelaySyncDB is an in-memory relaySyncDB so PushAll can be exercised
// without a live Postgres.
type fakeRelaySyncDB struct {
	relays []db.VPNServer
	exits  []db.VPNServer
	peers  []db.RelayExitPeer
	users  []db.User
}

func (f *fakeRelaySyncDB) ListActiveRelayServers(context.Context) ([]db.VPNServer, error) {
	return f.relays, nil
}
func (f *fakeRelaySyncDB) ListActiveRemoteExitServers(context.Context) ([]db.VPNServer, error) {
	return f.exits, nil
}
func (f *fakeRelaySyncDB) ListActiveRelayExitPeers(context.Context) ([]db.RelayExitPeer, error) {
	return f.peers, nil
}
func (f *fakeRelaySyncDB) ListActiveVPNUsers(context.Context) ([]db.User, error) {
	return f.users, nil
}

func strptr(s string) *string { return &s }

func newTestSyncer(database relaySyncDB, secrets map[string]string) *RelayUserSyncer {
	return &RelayUserSyncer{
		db:          database,
		secrets:     secrets,
		logger:      zap.NewNop(),
		pushTimeout: 5 * time.Second,
		stopCh:      make(chan struct{}),
	}
}

// GRA-PARITY (2026-05-31): PushAll must sync the active user set to a remote
// EXIT node on the VLESS Reality inbound, even with zero relay nodes — this is
// the fix that stops post-bake users getting a silent Reality reject on GRA.
func TestPushAll_SyncsRemoteExitVLESS(t *testing.T) {
	var (
		mu       sync.Mutex
		gotPath  string
		gotAuth  string
		gotUsers []map[string]any
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		var body struct {
			Users []map[string]any `json:"users"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		gotUsers = body.Users
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	fake := &fakeRelaySyncDB{
		exits: []db.VPNServer{{Key: "gra1", UserAPIURL: strptr(srv.URL)}},
		users: []db.User{
			{VPNUsername: strptr("device_abc"), VPNUUID: strptr("uuid-1")},
			{VPNUsername: strptr("apple_xyz"), VPNUUID: strptr("uuid-2")},
		},
	}
	r := newTestSyncer(fake, map[string]string{"gra1": "s3cr3t"})

	if err := r.PushAll(context.Background()); err != nil {
		t.Fatalf("PushAll: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	if want := "/api/v1/inbounds/vless-reality-tcp/users"; gotPath != want {
		t.Errorf("push path = %q, want %q", gotPath, want)
	}
	if gotAuth != "Bearer s3cr3t" {
		t.Errorf("auth = %q, want %q", gotAuth, "Bearer s3cr3t")
	}
	if len(gotUsers) != 2 {
		t.Fatalf("pushed %d users to exit, want 2", len(gotUsers))
	}
}

// A remote exit present in the DB but without a configured Bearer secret must be
// skipped (logged), never pushed to with an empty token.
func TestPushAll_SkipsRemoteExitWithoutSecret(t *testing.T) {
	hit := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hit = true
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	fake := &fakeRelaySyncDB{
		exits: []db.VPNServer{{Key: "gra1", UserAPIURL: strptr(srv.URL)}},
		users: []db.User{{VPNUsername: strptr("u"), VPNUUID: strptr("x")}},
	}
	// secrets carries a different key — gra1 has no secret.
	r := newTestSyncer(fake, map[string]string{"msk": "other"})

	if err := r.PushAll(context.Background()); err != nil {
		t.Fatalf("PushAll: %v", err)
	}
	if hit {
		t.Error("remote exit without a secret must not receive a push")
	}
}
