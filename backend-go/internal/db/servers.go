package db

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// serverColumns lists all columns for the vpn_servers table.
const serverColumns = `id, key, name, flag, host, port, domain, sni, is_active, sort_order, created_at, updated_at`

// scanServers scans multiple server rows from pgx.Rows into a slice.
func scanServers(rows pgx.Rows) ([]VPNServer, error) {
	defer rows.Close()
	var servers []VPNServer
	for rows.Next() {
		var s VPNServer
		err := rows.Scan(
			&s.ID, &s.Key, &s.Name, &s.Flag, &s.Host, &s.Port,
			&s.Domain, &s.SNI, &s.IsActive, &s.SortOrder,
			&s.CreatedAt, &s.UpdatedAt,
		)
		if err != nil {
			return nil, err
		}
		servers = append(servers, s)
	}
	return servers, rows.Err()
}

// ListActiveServers returns all active VPN servers, ordered by sort_order.
func (db *DB) ListActiveServers(ctx context.Context) ([]VPNServer, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	rows, err := db.Pool.Query(ctx, `
		SELECT `+serverColumns+`
		FROM vpn_servers
		WHERE is_active = true
		ORDER BY sort_order, id`)
	if err != nil {
		return nil, err
	}
	return scanServers(rows)
}

// ListAllServers returns all VPN servers (active and inactive), ordered by sort_order.
func (db *DB) ListAllServers(ctx context.Context) ([]VPNServer, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	rows, err := db.Pool.Query(ctx, `
		SELECT `+serverColumns+`
		FROM vpn_servers
		ORDER BY sort_order, id`)
	if err != nil {
		return nil, err
	}
	return scanServers(rows)
}

// FindServerByKey returns the VPN server matching the given key, or nil if not found.
func (db *DB) FindServerByKey(ctx context.Context, key string) (*VPNServer, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	var s VPNServer
	err := db.Pool.QueryRow(ctx, `
		SELECT `+serverColumns+`
		FROM vpn_servers
		WHERE key = $1`, key).Scan(
		&s.ID, &s.Key, &s.Name, &s.Flag, &s.Host, &s.Port,
		&s.Domain, &s.SNI, &s.IsActive, &s.SortOrder,
		&s.CreatedAt, &s.UpdatedAt,
	)
	if err != nil {
		if err == pgx.ErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	return &s, nil
}
