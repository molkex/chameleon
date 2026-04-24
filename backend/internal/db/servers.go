package db

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// serverColumns lists all columns for the vpn_servers table.
const serverColumns = `id, key, name, flag, host, port, domain, sni, reality_public_key, reality_private_key, is_active, sort_order,
	provider_name, cost_monthly, provider_url, provider_login, provider_password, notes,
	hysteria2_port, tuic_port,
	role, country_code, user_api_url, category,
	created_at, updated_at`

// decryptProviderPassword unwraps a stored provider_password through the
// configured Cipher. Plaintext rows pass through unchanged (lazy migration).
// On decrypt failure (corrupt blob, wrong KEK) the value is returned empty
// rather than crashing the read path — the admin UI just shows blank.
func (db *DB) decryptProviderPassword(stored string) string {
	if db.Cipher == nil || stored == "" {
		return stored
	}
	plain, err := db.Cipher.Decrypt(stored)
	if err != nil {
		return ""
	}
	return plain
}

// encryptProviderPassword wraps a plaintext provider_password for storage.
// Returns the input unchanged when no Cipher is configured (encryption
// disabled). Empty input stays empty so DB upserts that COALESCE on empty
// keep their "preserve existing" semantics.
func (db *DB) encryptProviderPassword(plain string) string {
	if db.Cipher == nil || plain == "" {
		return plain
	}
	ct, err := db.Cipher.Encrypt(plain)
	if err != nil {
		return plain
	}
	return ct
}

// scanServers scans multiple server rows from pgx.Rows into a slice.
func (db *DB) scanServers(rows pgx.Rows) ([]VPNServer, error) {
	defer rows.Close()
	var servers []VPNServer
	for rows.Next() {
		var s VPNServer
		err := rows.Scan(
			&s.ID, &s.Key, &s.Name, &s.Flag, &s.Host, &s.Port,
			&s.Domain, &s.SNI, &s.RealityPublicKey, &s.RealityPrivateKey, &s.IsActive, &s.SortOrder,
			&s.ProviderName, &s.CostMonthly, &s.ProviderURL, &s.ProviderLogin, &s.ProviderPassword, &s.Notes,
			&s.Hysteria2Port, &s.TUICPort,
			&s.Role, &s.CountryCode, &s.UserAPIURL, &s.Category,
			&s.CreatedAt, &s.UpdatedAt,
		)
		if err != nil {
			return nil, err
		}
		s.ProviderPassword = db.decryptProviderPassword(s.ProviderPassword)
		servers = append(servers, s)
	}
	return servers, rows.Err()
}

// ListActiveRelayExitPeers returns all active relay→exit WG peer entries.
// A single row represents one WG tunnel that routes one VLESS inbound port
// on a relay to one exit node.
func (db *DB) ListActiveRelayExitPeers(ctx context.Context) ([]RelayExitPeer, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	rows, err := db.Pool.Query(ctx, `
		SELECT id, relay_server_key, exit_server_key, relay_listen_port, relay_inbound_tag,
		       wg_exit_endpoint_port, wg_exit_pub, wg_relay_peer_priv, wg_relay_peer_pub,
		       wg_subnet_cidr, wg_relay_address,
		       is_active, created_at, updated_at
		FROM relay_exit_peers
		WHERE is_active = true
		ORDER BY relay_server_key, exit_server_key`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var peers []RelayExitPeer
	for rows.Next() {
		var p RelayExitPeer
		if err := rows.Scan(
			&p.ID, &p.RelayServerKey, &p.ExitServerKey, &p.RelayListenPort, &p.RelayInboundTag,
			&p.WGExitEndpointPort, &p.WGExitPub, &p.WGRelayPeerPriv, &p.WGRelayPeerPub,
			&p.WGSubnetCIDR, &p.WGRelayAddress,
			&p.IsActive, &p.CreatedAt, &p.UpdatedAt,
		); err != nil {
			return nil, err
		}
		peers = append(peers, p)
	}
	return peers, rows.Err()
}

// ListActiveRelayServers returns all active VPN servers with role='relay'.
// Used by RelayUserSyncer to know which remote sing-box instances to push
// users to. Only servers with a non-empty user_api_url are considered
// sync-targetable.
func (db *DB) ListActiveRelayServers(ctx context.Context) ([]VPNServer, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	rows, err := db.Pool.Query(ctx, `
		SELECT `+serverColumns+`
		FROM vpn_servers
		WHERE role = 'relay' AND is_active = true AND user_api_url IS NOT NULL
		ORDER BY sort_order, id`)
	if err != nil {
		return nil, err
	}
	return db.scanServers(rows)
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
	return db.scanServers(rows)
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
	return db.scanServers(rows)
}

// CreateServer inserts a new VPN server and returns it with generated fields.
func (db *DB) CreateServer(ctx context.Context, s *VPNServer) (*VPNServer, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	var created VPNServer
	err := db.Pool.QueryRow(ctx, `
		INSERT INTO vpn_servers (key, name, flag, host, port, domain, sni, reality_public_key, reality_private_key, is_active, sort_order,
			provider_name, cost_monthly, provider_url, provider_login, provider_password, notes,
			role, country_code, user_api_url, category)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17,
			COALESCE(NULLIF($18, ''), 'exit'), $19, $20, COALESCE(NULLIF($21, ''), 'standard'))
		RETURNING `+serverColumns,
		s.Key, s.Name, s.Flag, s.Host, s.Port, s.Domain, s.SNI, s.RealityPublicKey, s.RealityPrivateKey, s.IsActive, s.SortOrder,
		s.ProviderName, s.CostMonthly, s.ProviderURL, s.ProviderLogin, db.encryptProviderPassword(s.ProviderPassword), s.Notes,
		s.Role, s.CountryCode, s.UserAPIURL, s.Category,
	).Scan(
		&created.ID, &created.Key, &created.Name, &created.Flag, &created.Host, &created.Port,
		&created.Domain, &created.SNI, &created.RealityPublicKey, &created.RealityPrivateKey, &created.IsActive, &created.SortOrder,
		&created.ProviderName, &created.CostMonthly, &created.ProviderURL, &created.ProviderLogin, &created.ProviderPassword, &created.Notes,
		&created.Hysteria2Port, &created.TUICPort,
		&created.Role, &created.CountryCode, &created.UserAPIURL, &created.Category,
		&created.CreatedAt, &created.UpdatedAt,
	)
	if err != nil {
		return nil, err
	}
	created.ProviderPassword = db.decryptProviderPassword(created.ProviderPassword)
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
		    role = COALESCE(NULLIF($19, ''), role),
		    country_code = $20,
		    user_api_url = $21,
		    category = COALESCE(NULLIF($22, ''), category),
		    updated_at = NOW()
		WHERE id = $1
		RETURNING `+serverColumns,
		id, s.Key, s.Name, s.Flag, s.Host, s.Port, s.Domain, s.SNI, s.RealityPublicKey, s.RealityPrivateKey, s.IsActive, s.SortOrder,
		s.ProviderName, s.CostMonthly, s.ProviderURL, s.ProviderLogin, db.encryptProviderPassword(s.ProviderPassword), s.Notes,
		s.Role, s.CountryCode, s.UserAPIURL, s.Category,
	).Scan(
		&updated.ID, &updated.Key, &updated.Name, &updated.Flag, &updated.Host, &updated.Port,
		&updated.Domain, &updated.SNI, &updated.RealityPublicKey, &updated.RealityPrivateKey, &updated.IsActive, &updated.SortOrder,
		&updated.ProviderName, &updated.CostMonthly, &updated.ProviderURL, &updated.ProviderLogin, &updated.ProviderPassword, &updated.Notes,
		&updated.Hysteria2Port, &updated.TUICPort,
		&updated.Role, &updated.CountryCode, &updated.UserAPIURL, &updated.Category,
		&updated.CreatedAt, &updated.UpdatedAt,
	)
	if err != nil {
		return nil, err
	}
	updated.ProviderPassword = db.decryptProviderPassword(updated.ProviderPassword)
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
		&s.Hysteria2Port, &s.TUICPort,
		&s.Role, &s.CountryCode, &s.UserAPIURL, &s.Category,
		&s.CreatedAt, &s.UpdatedAt,
	)
	if err != nil {
		if err == pgx.ErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	s.ProviderPassword = db.decryptProviderPassword(s.ProviderPassword)
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
		&s.Hysteria2Port, &s.TUICPort,
		&s.Role, &s.CountryCode, &s.UserAPIURL, &s.Category,
		&s.CreatedAt, &s.UpdatedAt,
	)
	if err != nil {
		if err == pgx.ErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	s.ProviderPassword = db.decryptProviderPassword(s.ProviderPassword)
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

// ServersChangedSince returns all servers with updated_at > since.
func (db *DB) ServersChangedSince(ctx context.Context, since time.Time) ([]VPNServer, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	rows, err := db.Pool.Query(ctx, `
		SELECT `+serverColumns+`
		FROM vpn_servers
		WHERE updated_at > $1
		ORDER BY id`, since)
	if err != nil {
		return nil, err
	}
	return db.scanServers(rows)
}

// UpsertServerByKey inserts or updates a server by key.
// Conflict resolution: latest updated_at wins, BUT sensitive fields
// (reality_*, provider_*) are preserved against empty overwrites. This
// prevents a fresh node with empty/default rows from wiping real Reality
// keys or provider credentials on peers during cluster sync — see the
// 2026-04-14 incident in docs/TROUBLESHOOTING.md.
//
// Rule: if EXCLUDED.<field> is '' and vpn_servers.<field> is non-empty,
// keep the existing value. Operators editing via admin panel always write
// full values, so this doesn't block legitimate updates.
//
// Returns true if the row was actually modified.
func (db *DB) UpsertServerByKey(ctx context.Context, s *VPNServer) (bool, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	// Role is persisted via COALESCE(NULLIF(..., ''), ...) so a cluster peer
	// pre-dating the relay architecture can't wipe the role back to default
	// (old peers don't serialize Role in SyncServer, so it arrives '').
	tag, err := db.Pool.Exec(ctx, `
		INSERT INTO vpn_servers (key, name, flag, host, port, domain, sni,
			reality_public_key, reality_private_key, is_active, sort_order,
			provider_name, cost_monthly, provider_url, provider_login, provider_password, notes,
			role, country_code, user_api_url, category,
			updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17,
			COALESCE(NULLIF($18, ''), 'exit'), $19, $20, COALESCE(NULLIF($21, ''), 'standard'),
			$22)
		ON CONFLICT (key) DO UPDATE SET
			name = EXCLUDED.name, flag = EXCLUDED.flag, host = EXCLUDED.host, port = EXCLUDED.port,
			domain = EXCLUDED.domain, sni = EXCLUDED.sni,
			reality_public_key = COALESCE(NULLIF(EXCLUDED.reality_public_key, ''), vpn_servers.reality_public_key),
			reality_private_key = COALESCE(NULLIF(EXCLUDED.reality_private_key, ''), vpn_servers.reality_private_key),
			is_active = EXCLUDED.is_active, sort_order = EXCLUDED.sort_order,
			provider_name = COALESCE(NULLIF(EXCLUDED.provider_name, ''), vpn_servers.provider_name),
			cost_monthly = EXCLUDED.cost_monthly,
			provider_url = COALESCE(NULLIF(EXCLUDED.provider_url, ''), vpn_servers.provider_url),
			provider_login = COALESCE(NULLIF(EXCLUDED.provider_login, ''), vpn_servers.provider_login),
			provider_password = COALESCE(NULLIF(EXCLUDED.provider_password, ''), vpn_servers.provider_password),
			notes = COALESCE(NULLIF(EXCLUDED.notes, ''), vpn_servers.notes),
			role = COALESCE(NULLIF(EXCLUDED.role, ''), vpn_servers.role),
			country_code = COALESCE(EXCLUDED.country_code, vpn_servers.country_code),
			user_api_url = COALESCE(EXCLUDED.user_api_url, vpn_servers.user_api_url),
			category = COALESCE(NULLIF(EXCLUDED.category, ''), vpn_servers.category),
			updated_at = EXCLUDED.updated_at
		WHERE vpn_servers.updated_at < EXCLUDED.updated_at`,
		s.Key, s.Name, s.Flag, s.Host, s.Port, s.Domain, s.SNI,
		s.RealityPublicKey, s.RealityPrivateKey, s.IsActive, s.SortOrder,
		s.ProviderName, s.CostMonthly, s.ProviderURL, s.ProviderLogin, db.encryptProviderPassword(s.ProviderPassword), s.Notes,
		s.Role, s.CountryCode, s.UserAPIURL, s.Category,
		s.UpdatedAt,
	)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}
