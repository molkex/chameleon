//go:build integration

// testdb_test.go brings up a throwaway Postgres for the payments
// integration suite. Mirrors internal/db/users_test.go: gated behind the
// `integration` build tag, skips (not fails) when Docker is unavailable.
//
//	go test -tags=integration ./internal/payments/...
package payments

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"
)

// startTestPool spins up a fresh Postgres, applies every migration, and
// returns a connected pool. Each call is an isolated database.
func startTestPool(t *testing.T) *pgxpool.Pool {
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
	t.Cleanup(func() { _ = container.Terminate(context.Background()) })

	connStr, err := container.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		t.Fatalf("conn string: %v", err)
	}

	pool, err := pgxpool.New(ctx, connStr)
	if err != nil {
		t.Fatalf("pgxpool.New: %v", err)
	}
	t.Cleanup(pool.Close)

	if err := applyMigrations(ctx, pool); err != nil {
		t.Fatalf("migrations: %v", err)
	}
	return pool
}

// applyMigrations runs init.sql first, then every other *.sql alphabetically.
func applyMigrations(ctx context.Context, pool *pgxpool.Pool) error {
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
		if _, err := pool.Exec(ctx, string(body)); err != nil {
			return fmt.Errorf("apply %s: %w", name, err)
		}
		return nil
	}
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

// findMigrations walks up from the test working dir to locate migrations/.
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

// makeUser inserts a minimal user and returns its id. expiry may be the zero
// value for a user with no subscription (NULL subscription_expiry).
func makeUser(t *testing.T, pool *pgxpool.Pool, expiry time.Time) int64 {
	t.Helper()
	ctx := context.Background()
	var id int64
	var err error
	if expiry.IsZero() {
		err = pool.QueryRow(ctx,
			`INSERT INTO users (is_active) VALUES (false) RETURNING id`).Scan(&id)
	} else {
		err = pool.QueryRow(ctx,
			`INSERT INTO users (is_active, subscription_expiry) VALUES (true, $1) RETURNING id`,
			expiry).Scan(&id)
	}
	if err != nil {
		t.Fatalf("makeUser: %v", err)
	}
	return id
}

// userState reads the fields RefundCharge / RestoreCharge mutate.
func userState(t *testing.T, pool *pgxpool.Pool, id int64) (expiry *time.Time, isActive bool) {
	t.Helper()
	err := pool.QueryRow(context.Background(),
		`SELECT subscription_expiry, is_active FROM users WHERE id = $1`, id).
		Scan(&expiry, &isActive)
	if err != nil {
		t.Fatalf("userState: %v", err)
	}
	return expiry, isActive
}

// paymentStatus reads the ledger row status for a (source, charge_id) pair.
func paymentStatus(t *testing.T, pool *pgxpool.Pool, source Source, chargeID string) string {
	t.Helper()
	var status string
	err := pool.QueryRow(context.Background(),
		`SELECT status FROM payments WHERE source = $1 AND charge_id = $2`,
		string(source), chargeID).Scan(&status)
	if err != nil {
		t.Fatalf("paymentStatus: %v", err)
	}
	return status
}
