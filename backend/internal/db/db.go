package db

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// ErrNotFound is returned when an update or delete targets a row that does not exist.
var ErrNotFound = errors.New("db: record not found")

// DB wraps pgxpool.Pool with helper methods for database access.
type DB struct {
	Pool *pgxpool.Pool
}

// New creates a new DB connection pool from the given configuration.
// It validates connectivity before returning.
func New(ctx context.Context, databaseURL string, maxConns, minConns int32, maxLifetime time.Duration) (*DB, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("db: parse config: %w", err)
	}

	cfg.MaxConns = maxConns
	cfg.MinConns = minConns
	cfg.MaxConnLifetime = maxLifetime
	cfg.MaxConnIdleTime = 5 * time.Minute
	cfg.HealthCheckPeriod = 30 * time.Second

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("db: create pool: %w", err)
	}

	// Verify connectivity immediately.
	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("db: ping: %w", err)
	}

	return &DB{Pool: pool}, nil
}

// Close closes the connection pool, releasing all resources.
func (db *DB) Close() {
	if db.Pool != nil {
		db.Pool.Close()
	}
}

// Health checks database connectivity by executing a ping.
func (db *DB) Health(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	return db.Pool.Ping(ctx)
}

// defaultTimeout returns a context with a 10-second timeout derived from the parent.
func defaultTimeout(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(ctx, 10*time.Second)
}
