//go:build integration

// sync_test.go covers the cluster handlePush path end-to-end with a real
// Postgres: a valid push with a couple of users gets upserted; a duplicate
// vpn_username conflict is logged and skipped (handler still returns 200).
//
// Run: go test -tags=integration ./internal/cluster/...
//
// Skips with a clear message when Docker is unreachable.

package cluster

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/labstack/echo/v4"
	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/config"
	"github.com/chameleonvpn/chameleon/internal/db"
)

func startTestDB(t *testing.T) *db.DB {
	t.Helper()
	if os.Getenv("SKIP_DOCKER_TESTS") != "" {
		t.Skip("SKIP_DOCKER_TESTS set — skipping integration test")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	c, err := postgres.Run(ctx, "postgres:16-alpine",
		postgres.WithDatabase("chameleon_test"),
		postgres.WithUsername("test"),
		postgres.WithPassword("test"),
		testcontainers.WithWaitStrategy(
			wait.ForLog("database system is ready to accept connections").
				WithOccurrence(2).
				WithStartupTimeout(60*time.Second),
		),
	)
	if err != nil {
		t.Skipf("Docker not available, skipping integration test: %v", err)
	}
	t.Cleanup(func() { _ = c.Terminate(context.Background()) })

	connStr, err := c.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		t.Fatalf("conn string: %v", err)
	}
	database, err := db.New(ctx, connStr, 4, 1, 5*time.Minute)
	if err != nil {
		t.Fatalf("db.New: %v", err)
	}
	t.Cleanup(database.Close)

	if err := applyMigrations(ctx, database); err != nil {
		t.Fatalf("migrations: %v", err)
	}
	return database
}

func applyMigrations(ctx context.Context, database *db.DB) error {
	dir, err := findMigrationsDir()
	if err != nil {
		return err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	exec := func(name string) error {
		body, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return err
		}
		_, err = database.Pool.Exec(ctx, string(body))
		return err
	}
	// init.sql first.
	for _, e := range entries {
		if e.Name() == "init.sql" {
			if err := exec(e.Name()); err != nil {
				return fmt.Errorf("init.sql: %w", err)
			}
		}
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".sql") || e.Name() == "init.sql" {
			continue
		}
		if err := exec(e.Name()); err != nil {
			return fmt.Errorf("%s: %w", e.Name(), err)
		}
	}
	return nil
}

func findMigrationsDir() (string, error) {
	wd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	dir := wd
	for i := 0; i < 6; i++ {
		c := filepath.Join(dir, "migrations")
		if info, err := os.Stat(c); err == nil && info.IsDir() {
			return c, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "", fmt.Errorf("migrations/ not found from %s", wd)
}

// TestHandlePushApplies verifies the happy path: a small batch of users is
// accepted and persisted, response counts match the input.
func TestHandlePushApplies(t *testing.T) {
	database := startTestDB(t)

	now := time.Now().UTC()
	body, err := json.Marshal(PushRequest{
		NodeID: "peer-A",
		Users: []SyncUser{
			{
				VPNUUID:     "ffffffff-1111-4111-8111-111111111111",
				VPNUsername: "device_pushone1",
				IsActive:    true,
				CreatedAt:   now,
				UpdatedAt:   now,
			},
			{
				VPNUUID:     "ffffffff-2222-4222-8222-222222222222",
				VPNUsername: "device_pushtwo2",
				IsActive:    true,
				CreatedAt:   now,
				UpdatedAt:   now,
			},
		},
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	h := &clusterHandler{
		db:     database,
		config: config.ClusterConfig{NodeID: "local"},
		logger: zap.NewNop(),
	}

	e := echo.New()
	req := httptest.NewRequest(http.MethodPost, "/api/cluster/push", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)

	if err := h.handlePush(c); err != nil {
		t.Fatalf("handlePush: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("status: want 200, got %d (body=%s)", rec.Code, rec.Body.String())
	}

	var resp PushResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.Received != 2 {
		t.Errorf("Received: want 2, got %d", resp.Received)
	}
	if resp.Applied != 2 {
		t.Errorf("Applied: want 2, got %d", resp.Applied)
	}

	// Verify rows landed.
	got, err := database.FindUserByVPNUUID(context.Background(),
		"ffffffff-1111-4111-8111-111111111111")
	if err != nil || got == nil {
		t.Fatalf("FindUserByVPNUUID: err=%v, got=%v", err, got)
	}
}

// TestHandlePushSkipsVPNUsernameConflict verifies that when a peer sends a
// user whose vpn_username collides with an existing local row (different
// vpn_uuid), the handler logs+skips that row but still returns 200 and
// applies the rest. This is the production scenario the
// isDuplicateVPNUsername filter exists for.
func TestHandlePushSkipsVPNUsernameConflict(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	now := time.Now().UTC()

	// Pre-existing local row.
	local := &db.User{
		VPNUsername: ptrStr("device_collide1"),
		VPNUUID:     ptrStr("aaaa1111-1111-4111-8111-111111111111"),
		VPNShortID:  ptrStr(""),
		IsActive:    true,
		CreatedAt:   now,
		UpdatedAt:   now,
	}
	if err := database.CreateUser(ctx, local); err != nil {
		t.Fatalf("CreateUser local: %v", err)
	}

	// Push: one fresh user (should apply), one with same username but
	// different uuid (should be skipped).
	body, err := json.Marshal(PushRequest{
		NodeID: "peer-A",
		Users: []SyncUser{
			{
				VPNUUID:     "bbbb2222-2222-4222-8222-222222222222",
				VPNUsername: "device_freshok1",
				IsActive:    true,
				CreatedAt:   now,
				UpdatedAt:   now,
			},
			{
				// SAME username as local.
				VPNUUID:     "cccc3333-3333-4333-8333-333333333333",
				VPNUsername: "device_collide1",
				IsActive:    true,
				CreatedAt:   now,
				UpdatedAt:   now,
			},
		},
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	h := &clusterHandler{
		db:     database,
		config: config.ClusterConfig{NodeID: "local"},
		logger: zap.NewNop(),
	}
	e := echo.New()
	req := httptest.NewRequest(http.MethodPost, "/api/cluster/push", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)

	if err := h.handlePush(c); err != nil {
		t.Fatalf("handlePush: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("status: want 200 (skip-and-continue), got %d body=%s",
			rec.Code, rec.Body.String())
	}

	// The conflicting uuid must NOT have been inserted.
	got, err := database.FindUserByVPNUUID(ctx, "cccc3333-3333-4333-8333-333333333333")
	if err != nil {
		t.Fatalf("FindUserByVPNUUID: %v", err)
	}
	if got != nil {
		t.Errorf("conflicting user should have been skipped, but found: %+v", got)
	}

	// The non-conflicting uuid must have landed.
	fresh, err := database.FindUserByVPNUUID(ctx, "bbbb2222-2222-4222-8222-222222222222")
	if err != nil || fresh == nil {
		t.Errorf("fresh user not inserted: err=%v fresh=%v", err, fresh)
	}
}

func ptrStr(s string) *string { return &s }
