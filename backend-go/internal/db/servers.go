package db

import (
	"context"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
)

// serverColumns lists all columns for the vpn_servers table.
const serverColumns = `id, key, name, flag, host, port, domain, sni, reality_public_key, reality_private_key, is_active, sort_order,
	provider_name, cost_monthly, provider_url, provider_login, provider_password, notes,
	created_at, updated_at`

// scanServers scans multiple server rows from pgx.Rows into a slice.
func scanServers(rows pgx.Rows) ([]VPNServer, error) {
	defer rows.Close()
	var servers []VPNServer
	for rows.Next() {
		var s VPNServer
		err := rows.Scan(
			&s.ID, &s.Key, &s.Name, &s.Flag, &s.Host, &s.Port,
			&s.Domain, &s.SNI, &s.RealityPublicKey, &s.RealityPrivateKey, &s.IsActive, &s.SortOrder,
			&s.ProviderName, &s.CostMonthly, &s.ProviderURL, &s.ProviderLogin, &s.ProviderPassword, &s.Notes,
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

// CreateServer inserts a new VPN server and returns it with generated fields.
func (db *DB) CreateServer(ctx context.Context, s *VPNServer) (*VPNServer, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	var created VPNServer
	err := db.Pool.QueryRow(ctx, `
		INSERT INTO vpn_servers (key, name, flag, host, port, domain, sni, reality_public_key, reality_private_key, is_active, sort_order,
			provider_name, cost_monthly, provider_url, provider_login, provider_password, notes)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17)
		RETURNING `+serverColumns,
		s.Key, s.Name, s.Flag, s.Host, s.Port, s.Domain, s.SNI, s.RealityPublicKey, s.RealityPrivateKey, s.IsActive, s.SortOrder,
		s.ProviderName, s.CostMonthly, s.ProviderURL, s.ProviderLogin, s.ProviderPassword, s.Notes,
	).Scan(
		&created.ID, &created.Key, &created.Name, &created.Flag, &created.Host, &created.Port,
		&created.Domain, &created.SNI, &created.RealityPublicKey, &created.RealityPrivateKey, &created.IsActive, &created.SortOrder,
		&created.ProviderName, &created.CostMonthly, &created.ProviderURL, &created.ProviderLogin, &created.ProviderPassword, &created.Notes,
		&created.CreatedAt, &created.UpdatedAt,
	)
	if err != nil {
		return nil, err
	}
	return &created, nil
}

// UpdateServer updates an existing VPN server by ID and returns the updated record.
func (db *DB) UpdateServer(ctx context.Context, id int64, s *VPNServer) (*VPNServer, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	var updated VPNServer
	err := db.Pool.QueryRow(ctx, `
		UPDATE vpn_servers
		SET key = $2, name = $3, flag = $4, host = $5, port = $6,
		    domain = $7, sni = $8, reality_public_key = $9, reality_private_key = $10,
		    is_active = $11, sort_order = $12,
		    provider_name = $13, cost_monthly = $14, provider_url = $15,
		    provider_login = $16, provider_password = $17, notes = $18,
		    updated_at = NOW()
		WHERE id = $1
		RETURNING `+serverColumns,
		id, s.Key, s.Name, s.Flag, s.Host, s.Port, s.Domain, s.SNI, s.RealityPublicKey, s.RealityPrivateKey, s.IsActive, s.SortOrder,
		s.ProviderName, s.CostMonthly, s.ProviderURL, s.ProviderLogin, s.ProviderPassword, s.Notes,
	).Scan(
		&updated.ID, &updated.Key, &updated.Name, &updated.Flag, &updated.Host, &updated.Port,
		&updated.Domain, &updated.SNI, &updated.RealityPublicKey, &updated.RealityPrivateKey, &updated.IsActive, &updated.SortOrder,
		&updated.ProviderName, &updated.CostMonthly, &updated.ProviderURL, &updated.ProviderLogin, &updated.ProviderPassword, &updated.Notes,
		&updated.CreatedAt, &updated.UpdatedAt,
	)
	if err != nil {
		return nil, err
	}
	return &updated, nil
}

// DeleteServer removes a VPN server by ID. Returns true if a row was deleted.
func (db *DB) DeleteServer(ctx context.Context, id int64) (bool, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	tag, err := db.Pool.Exec(ctx, `DELETE FROM vpn_servers WHERE id = $1`, id)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
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
		&s.Domain, &s.SNI, &s.RealityPublicKey, &s.RealityPrivateKey, &s.IsActive, &s.SortOrder,
		&s.ProviderName, &s.CostMonthly, &s.ProviderURL, &s.ProviderLogin, &s.ProviderPassword, &s.Notes,
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

// FindServerByID returns the VPN server matching the given id, or nil if not found.
func (db *DB) FindServerByID(ctx context.Context, id int64) (*VPNServer, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	var s VPNServer
	err := db.Pool.QueryRow(ctx, `
		SELECT `+serverColumns+`
		FROM vpn_servers
		WHERE id = $1`, id).Scan(
		&s.ID, &s.Key, &s.Name, &s.Flag, &s.Host, &s.Port,
		&s.Domain, &s.SNI, &s.RealityPublicKey, &s.RealityPrivateKey, &s.IsActive, &s.SortOrder,
		&s.ProviderName, &s.CostMonthly, &s.ProviderURL, &s.ProviderLogin, &s.ProviderPassword, &s.Notes,
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

// FindLocalServer returns the VPN server for the local node, identified by cluster node ID.
// Node ID "de-1" maps to server key "de", "nl-1" maps to "nl", etc.
func (db *DB) FindLocalServer(ctx context.Context, nodeID string) (*VPNServer, error) {
	parts := strings.Split(nodeID, "-")
	if len(parts) == 0 || parts[0] == "" {
		return nil, fmt.Errorf("invalid node ID: %q", nodeID)
	}
	return db.FindServerByKey(ctx, parts[0])
}
