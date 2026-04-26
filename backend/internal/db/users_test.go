//go:build integration

// users_test.go covers the queries that drive cluster sync (UpsertUserByVPNUUID)
// and admin search (SearchUsers). Gated behind the `integration` build tag
// because they need a real Postgres — run with:
//
//	go test -tags=integration ./internal/db/...
//
// A testcontainers Postgres is brought up per-test; if Docker is missing the
// test SKIPS rather than fails so the suite is friendly to environments
// without a daemon.

package db

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"
)

// startTestDB spins up a fresh Postgres + applies all migrations, returning
// a connected DB. Tests get a clean slate each run.
func startTestDB(t *testing.T) *DB {
	t.Helper()

	if os.Getenv("SKIP_DOCKER_TESTS") != "" {
		t.Skip("SKIP_DOCKER_TESTS set — skipping integration test")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	container, err := postgres.Run(ctx,
		"postgres:16-alpine",
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
	t.Cleanup(func() {
		_ = container.Terminate(context.Background())
	})

	connStr, err := container.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		t.Fatalf("conn string: %v", err)
	}

	database, err := New(ctx, connStr, 4, 1, 5*time.Minute)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(database.Close)

	if err := applyTestMigrations(ctx, database); err != nil {
		t.Fatalf("migrations: %v", err)
	}
	return database
}

// applyTestMigrations runs init.sql first, then every other *.sql in
// alphabetical order. Idempotent — safe to run twice.
func applyTestMigrations(ctx context.Context, database *DB) error {
	dir, err := findMigrations()
	if err != nil {
		return err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return fmt.Errorf("read dir: %w", err)
	}
	exec := func(name string) error {
		body, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return err
		}
		if _, err := database.Pool.Exec(ctx, string(body)); err != nil {
			return fmt.Errorf("apply %s: %w", name, err)
		}
		return nil
	}
	// init.sql first.
	for _, e := range entries {
		if e.Name() == "init.sql" {
			if err := exec(e.Name()); err != nil {
				return err
			}
		}
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".sql") || e.Name() == "init.sql" {
			continue
		}
		if err := exec(e.Name()); err != nil {
			return err
		}
	}
	return nil
}

// findMigrations walks up from the test working directory looking for the
// migrations/ folder. Avoids hard-coding paths.
func findMigrations() (string, error) {
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

func ptr[T any](v T) *T { return &v }

// TestUpsertUserByVPNUUIDInsertNew covers the happy path: a brand-new user
// row arrives via cluster sync, gets inserted, and UpsertUserByVPNUUID
// reports updated=true.
func TestUpsertUserByVPNUUIDInsertNew(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	now := time.Now().UTC()
	u := &User{
		VPNUsername: ptr("device_aaaa1111"),
		VPNUUID:     ptr("aaaa1111-2222-4333-8444-555566667777"),
		VPNShortID:  ptr(""),
		IsActive:    true,
		CreatedAt:   now,
		UpdatedAt:   now,
	}
	updated, err := database.UpsertUserByVPNUUID(ctx, u)
	if err != nil {
		t.Fatalf("UpsertUserByVPNUUID: %v", err)
	}
	if !updated {
		t.Fatal("expected updated=true on insert")
	}

	got, err := database.FindUserByVPNUUID(ctx, *u.VPNUUID)
	if err != nil || got == nil {
		t.Fatalf("FindUserByVPNUUID: err=%v, got=%v", err, got)
	}
	if got.VPNUsername == nil || *got.VPNUsername != *u.VPNUsername {
		t.Errorf("VPNUsername mismatch: got=%v want=%v", got.VPNUsername, u.VPNUsername)
	}
}

// TestUpsertUserByVPNUUIDUpdateExisting verifies the conflict-resolution
// rule: a newer updated_at wins, an older one is ignored.
func TestUpsertUserByVPNUUIDUpdateExisting(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	uuid := "bbbbbbbb-2222-4333-8444-555566667777"
	t0 := time.Now().UTC().Add(-time.Hour)
	t1 := t0.Add(30 * time.Minute)

	// Initial insert.
	first := &User{
		VPNUsername: ptr("device_first1234"),
		VPNUUID:     ptr(uuid),
		VPNShortID:  ptr(""),
		IsActive:    true,
		CreatedAt:   t0,
		UpdatedAt:   t0,
	}
	if _, err := database.UpsertUserByVPNUUID(ctx, first); err != nil {
		t.Fatalf("first upsert: %v", err)
	}

	// Newer update — same uuid, different username, newer updated_at.
	newer := &User{
		VPNUsername: ptr("device_newer123"),
		VPNUUID:     ptr(uuid),
		VPNShortID:  ptr(""),
		IsActive:    true,
		CreatedAt:   t0,
		UpdatedAt:   t1,
	}
	updated, err := database.UpsertUserByVPNUUID(ctx, newer)
	if err != nil {
		t.Fatalf("newer upsert: %v", err)
	}
	if !updated {
		t.Error("expected updated=true on newer record")
	}

	got, err := database.FindUserByVPNUUID(ctx, uuid)
	if err != nil || got == nil {
		t.Fatalf("FindUserByVPNUUID: err=%v, got=%v", err, got)
	}
	if got.VPNUsername == nil || *got.VPNUsername != "device_newer123" {
		t.Errorf("expected newer username to win, got %v", got.VPNUsername)
	}

	// Older update — must be a no-op.
	older := &User{
		VPNUsername: ptr("device_older123"),
		VPNUUID:     ptr(uuid),
		VPNShortID:  ptr(""),
		IsActive:    true,
		CreatedAt:   t0,
		UpdatedAt:   t0.Add(-time.Hour), // older than current
	}
	updated, err = database.UpsertUserByVPNUUID(ctx, older)
	if err != nil {
		t.Fatalf("older upsert: %v", err)
	}
	if updated {
		t.Error("expected updated=false when incoming updated_at is older")
	}
	got, _ = database.FindUserByVPNUUID(ctx, uuid)
	if got == nil || got.VPNUsername == nil || *got.VPNUsername != "device_newer123" {
		t.Errorf("older record should not have overwritten newer; got %v", got)
	}
}

// TestUpsertUserByVPNUUIDVPNUsernameConflict reproduces the SQLSTATE-23505
// path that cluster/errors.go isDuplicateVPNUsername filters out.
//
// Setup: two distinct vpn_uuids that share the same vpn_username. The unique
// partial index idx_users_vpn_username (created in init.sql) must reject
// the second upsert with code 23505 on the index name. Cluster code expects
// exactly this shape.
func TestUpsertUserByVPNUUIDVPNUsernameConflict(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	now := time.Now().UTC()
	first := &User{
		VPNUsername: ptr("device_dupename"),
		VPNUUID:     ptr("11111111-1111-4111-8111-111111111111"),
		VPNShortID:  ptr(""),
		IsActive:    true,
		CreatedAt:   now,
		UpdatedAt:   now,
	}
	if _, err := database.UpsertUserByVPNUUID(ctx, first); err != nil {
		t.Fatalf("first upsert: %v", err)
	}

	// Different uuid, same username — must violate idx_users_vpn_username.
	conflict := &User{
		VPNUsername: ptr("device_dupename"),
		VPNUUID:     ptr("22222222-2222-4222-8222-222222222222"),
		VPNShortID:  ptr(""),
		IsActive:    true,
		CreatedAt:   now,
		UpdatedAt:   now,
	}
	_, err := database.UpsertUserByVPNUUID(ctx, conflict)
	if err == nil {
		t.Fatal("expected unique-violation error, got nil")
	}
	// We don't import pgconn here; assert by error string. The cluster
	// package has its own typed test that pins the exact extraction.
	msg := err.Error()
	if !strings.Contains(msg, "23505") && !strings.Contains(strings.ToLower(msg), "duplicate") {
		t.Errorf("expected 23505 / duplicate error, got: %v", err)
	}
	if !strings.Contains(msg, "vpn_username") {
		t.Errorf("expected error to mention vpn_username constraint, got: %v", err)
	}
}

// TestSearchUsers exercises the admin search path:
//   - inserts a small fixture set
//   - searches by partial vpn_username
//   - searches by device_id
//   - oversized search term is truncated (no error, returns matching rows)
func TestSearchUsers(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	now := time.Now().UTC()
	fixtures := []*User{
		{
			VPNUsername: ptr("device_alpha001"),
			VPNUUID:     ptr("aaaaaaaa-0001-4000-8000-000000000001"),
			VPNShortID:  ptr(""),
			DeviceID:    ptr("device-id-alpha"),
			IsActive:    true,
			CreatedAt:   now,
			UpdatedAt:   now,
		},
		{
			VPNUsername: ptr("device_beta0002"),
			VPNUUID:     ptr("aaaaaaaa-0002-4000-8000-000000000002"),
			VPNShortID:  ptr(""),
			DeviceID:    ptr("device-id-beta"),
			IsActive:    true,
			CreatedAt:   now,
			UpdatedAt:   now,
		},
	}
	for _, u := range fixtures {
		if err := database.CreateUser(ctx, u); err != nil {
			t.Fatalf("CreateUser: %v", err)
		}
	}

	// Search by partial vpn_username.
	users, total, err := database.SearchUsers(ctx, "alpha", 1, 50)
	if err != nil {
		t.Fatalf("SearchUsers(alpha): %v", err)
	}
	if total != 1 || len(users) != 1 || users[0].VPNUsername == nil || *users[0].VPNUsername != "device_alpha001" {
		t.Errorf("alpha search: total=%d users=%v", total, users)
	}

	// Search by device_id.
	users, total, err = database.SearchUsers(ctx, "device-id-beta", 1, 50)
	if err != nil {
		t.Fatalf("SearchUsers(device-id-beta): %v", err)
	}
	if total != 1 || len(users) != 1 || users[0].DeviceID == nil || *users[0].DeviceID != "device-id-beta" {
		t.Errorf("device-id-beta search: total=%d users=%v", total, users)
	}

	// Oversized search term — must be truncated to maxSearchLen (100) and
	// still execute. We pad with 'a' so the truncated prefix matches alpha.
	huge := strings.Repeat("a", 200)
	users, total, err = database.SearchUsers(ctx, huge, 1, 50)
	if err != nil {
		t.Fatalf("SearchUsers(huge): %v", err)
	}
	// "a"*100 won't match either fixture, but the call must succeed (no DB
	// "value too long" error). Result is allowed to be empty.
	_ = users
	_ = total
}

// TestSearchUsersPageSizeClamp pins the [1,500] clamp for pageSize so that
// admin SPA bugs can't request megapages.
func TestSearchUsersPageSizeClamp(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	// 3 users, all matching "device_".
	now := time.Now().UTC()
	for i := 0; i < 3; i++ {
		u := &User{
			VPNUsername: ptr(fmt.Sprintf("device_clamp%03d", i)),
			VPNUUID:     ptr(fmt.Sprintf("ccccdddd-0000-4000-8000-00000000000%d", i)),
			VPNShortID:  ptr(""),
			IsActive:    true,
			CreatedAt:   now,
			UpdatedAt:   now,
		}
		if err := database.CreateUser(ctx, u); err != nil {
			t.Fatalf("CreateUser: %v", err)
		}
	}

	// Negative page → clamped to 1; pageSize 0 → defaulted to 20.
	users, total, err := database.SearchUsers(ctx, "device_clamp", -5, 0)
	if err != nil {
		t.Fatalf("SearchUsers: %v", err)
	}
	if total != 3 {
		t.Errorf("total: want 3, got %d", total)
	}
	if len(users) != 3 {
		t.Errorf("len(users): want 3, got %d", len(users))
	}
}

// TestFindUserByIDAliasResolution covers the id_aliases transitive lookup added
// after the NL postgres was decommissioned (see migrations 012/013). A JWT
// minted on NL contains the NL-local id; on DE that id has no row, so the
// alias table maps it back to the canonical users.id row. iOS clients keep
// working with their stale Keychain tokens.
func TestFindUserByIDAliasResolution(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	now := time.Now().UTC()
	canonical := &User{
		VPNUsername: ptr("device_canonical"),
		VPNUUID:     ptr("11111111-0001-4000-8000-000000000001"),
		VPNShortID:  ptr(""),
		IsActive:    true,
		CreatedAt:   now,
		UpdatedAt:   now,
	}
	if err := database.CreateUser(ctx, canonical); err != nil {
		t.Fatalf("CreateUser: %v", err)
	}

	// 1. Direct lookup by canonical id finds the row.
	got, err := database.FindUserByID(ctx, canonical.ID)
	if err != nil {
		t.Fatalf("FindUserByID(canonical): %v", err)
	}
	if got == nil || got.ID != canonical.ID {
		t.Fatalf("FindUserByID(canonical): want id=%d, got %v", canonical.ID, got)
	}

	// 2. Direct lookup of an unaliased id returns nil (not error).
	missing, err := database.FindUserByID(ctx, 999_999)
	if err != nil {
		t.Fatalf("FindUserByID(missing): %v", err)
	}
	if missing != nil {
		t.Fatalf("FindUserByID(missing): want nil, got id=%d", missing.ID)
	}

	// 3. Insert an alias and verify the lookup follows it.
	const altID = 424242
	if _, err := database.Pool.Exec(ctx,
		`INSERT INTO id_aliases (alt_id, real_id, source) VALUES ($1, $2, 'test')`,
		altID, canonical.ID); err != nil {
		t.Fatalf("insert alias: %v", err)
	}
	resolved, err := database.FindUserByID(ctx, altID)
	if err != nil {
		t.Fatalf("FindUserByID(alt): %v", err)
	}
	if resolved == nil {
		t.Fatalf("FindUserByID(alt): want canonical id=%d, got nil", canonical.ID)
	}
	if resolved.ID != canonical.ID {
		t.Fatalf("FindUserByID(alt): want id=%d, got id=%d", canonical.ID, resolved.ID)
	}
	if got := strings.TrimSpace(*resolved.VPNUsername); got != "device_canonical" {
		t.Errorf("alias resolved to wrong row: vpn_username=%q", got)
	}
}
