//go:build integration

package payments

import (
	"context"
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

// Audit H-008 (2026-05-26): the expired-receipt guard in
// subscription.go probes the payments ledger via HasCharge to
// distinguish "fresh replay of stale receipt" (must reject) from
// "Restore Purchases for a known charge" (must allow). These tests
// pin the behavior of HasCharge itself: only completed rows count,
// and the (source, charge_id) pair is the lookup key.

func startTestPaymentsDB(t *testing.T) *Service {
	t.Helper()
	ctx := context.Background()
	pgC, err := postgres.Run(ctx,
		"postgres:16-alpine",
		postgres.WithDatabase("chameleon"),
		postgres.WithUsername("chameleon"),
		postgres.WithPassword("test"),
		testcontainers.WithWaitStrategy(
			wait.ForLog("database system is ready to accept connections").
				WithOccurrence(2).
				WithStartupTimeout(60*time.Second),
		),
	)
	if err != nil {
		t.Skipf("docker not available: %v", err)
	}
	t.Cleanup(func() { _ = pgC.Terminate(ctx) })

	dsn, err := pgC.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		t.Fatalf("ConnectionString: %v", err)
	}
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("pgxpool.New: %v", err)
	}
	t.Cleanup(pool.Close)

	// Apply migrations
	migrations := findMigrations(t)
	files, err := os.ReadDir(migrations)
	if err != nil {
		t.Fatalf("ReadDir migrations: %v", err)
	}
	for _, f := range files {
		if !strings.HasSuffix(f.Name(), ".sql") {
			continue
		}
		sql, err := os.ReadFile(filepath.Join(migrations, f.Name()))
		if err != nil {
			t.Fatalf("read %s: %v", f.Name(), err)
		}
		if _, err := pool.Exec(ctx, string(sql)); err != nil {
			t.Fatalf("apply %s: %v", f.Name(), err)
		}
	}

	return New(pool)
}

func findMigrations(t *testing.T) string {
	t.Helper()
	wd, _ := os.Getwd()
	for {
		candidate := filepath.Join(wd, "migrations")
		if info, err := os.Stat(candidate); err == nil && info.IsDir() {
			return candidate
		}
		parent := filepath.Dir(wd)
		if parent == wd {
			t.Fatalf("migrations/ not found from %s", wd)
		}
		wd = parent
	}
}

func TestHasCharge_ReturnsFalseForUnknownChargeID(t *testing.T) {
	svc := startTestPaymentsDB(t)
	ctx := context.Background()
	has, err := svc.HasCharge(ctx, SourceAppleIAP, "never-seen-tx-id-12345")
	if err != nil {
		t.Fatalf("HasCharge: %v", err)
	}
	if has {
		t.Error("HasCharge must return false for an unknown charge_id (H-008 regression)")
	}
}

func TestHasCharge_ReturnsTrueAfterCreditDays(t *testing.T) {
	svc := startTestPaymentsDB(t)
	ctx := context.Background()

	// Need a user row first — payments.user_id has a FK to users.id.
	_, err := svc.pool.Exec(ctx, `
		INSERT INTO users (id, device_id, is_active, created_at, updated_at)
		VALUES (1, 'test_device', true, NOW(), NOW())`)
	if err != nil {
		t.Fatalf("seed user: %v", err)
	}

	chargeID := "test-original-tx-12345"
	if _, err := svc.CreditDays(ctx, Credit{
		UserID:   1,
		Source:   SourceAppleIAP,
		ChargeID: chargeID,
		Days:     30,
	}); err != nil {
		t.Fatalf("CreditDays: %v", err)
	}

	has, err := svc.HasCharge(ctx, SourceAppleIAP, chargeID)
	if err != nil {
		t.Fatalf("HasCharge after credit: %v", err)
	}
	if !has {
		t.Error("HasCharge must return true after CreditDays inserted a row (H-008 regression)")
	}
}

func TestHasCharge_DiscriminatesBySource(t *testing.T) {
	svc := startTestPaymentsDB(t)
	ctx := context.Background()

	// One user, two payments with the same charge_id but different
	// sources. HasCharge must return true only for the matching source.
	_, err := svc.pool.Exec(ctx, `
		INSERT INTO users (id, device_id, is_active, created_at, updated_at)
		VALUES (1, 'test_device', true, NOW(), NOW())`)
	if err != nil {
		t.Fatalf("seed user: %v", err)
	}

	cid := "shared-charge-id"
	if _, err := svc.CreditDays(ctx, Credit{
		UserID: 1, Source: SourceAppleIAP, ChargeID: cid, Days: 30,
	}); err != nil {
		t.Fatalf("CreditDays Apple: %v", err)
	}

	gotApple, _ := svc.HasCharge(ctx, SourceAppleIAP, cid)
	gotFK, _ := svc.HasCharge(ctx, SourceFreeKassa, cid)
	if !gotApple {
		t.Error("HasCharge(apple, X) should be true after Apple credit")
	}
	if gotFK {
		t.Error("HasCharge(freekassa, X) MUST be false when only Apple credit exists (source must discriminate)")
	}
}

