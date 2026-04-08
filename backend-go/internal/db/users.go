package db

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// userColumns lists all columns for the users table to avoid SELECT *.
const userColumns = `
	id, telegram_id, username, full_name, is_active, subscription_expiry,
	vpn_username, vpn_uuid, vpn_short_id, auth_provider, apple_id, device_id,
	original_transaction_id, app_store_product_id, ad_source,
	cumulative_traffic, device_limit, bot_blocked_at, phone_number, google_id,
	notified_3d, notified_1d, current_plan, subscription_token, activation_code,
	created_at, updated_at`

// scanUser scans a single user row from pgx.Row into a User struct.
func scanUser(row pgx.Row) (*User, error) {
	var u User
	err := row.Scan(
		&u.ID, &u.TelegramID, &u.Username, &u.FullName, &u.IsActive, &u.SubscriptionExpiry,
		&u.VPNUsername, &u.VPNUUID, &u.VPNShortID, &u.AuthProvider, &u.AppleID, &u.DeviceID,
		&u.OriginalTransactionID, &u.AppStoreProductID, &u.AdSource,
		&u.CumulativeTraffic, &u.DeviceLimit, &u.BotBlockedAt, &u.PhoneNumber, &u.GoogleID,
		&u.Notified3D, &u.Notified1D, &u.CurrentPlan, &u.SubscriptionToken, &u.ActivationCode,
		&u.CreatedAt, &u.UpdatedAt,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &u, nil
}

// scanUsers scans multiple user rows from pgx.Rows into a slice.
func scanUsers(rows pgx.Rows) ([]User, error) {
	defer rows.Close()
	var users []User
	for rows.Next() {
		var u User
		err := rows.Scan(
			&u.ID, &u.TelegramID, &u.Username, &u.FullName, &u.IsActive, &u.SubscriptionExpiry,
			&u.VPNUsername, &u.VPNUUID, &u.VPNShortID, &u.AuthProvider, &u.AppleID, &u.DeviceID,
			&u.OriginalTransactionID, &u.AppStoreProductID, &u.AdSource,
			&u.CumulativeTraffic, &u.DeviceLimit, &u.BotBlockedAt, &u.PhoneNumber, &u.GoogleID,
			&u.Notified3D, &u.Notified1D, &u.CurrentPlan, &u.SubscriptionToken, &u.ActivationCode,
			&u.CreatedAt, &u.UpdatedAt,
		)
		if err != nil {
			return nil, err
		}
		users = append(users, u)
	}
	return users, rows.Err()
}

// FindUserByDeviceID returns the user matching the given device_id, or nil if not found.
func (db *DB) FindUserByDeviceID(ctx context.Context, deviceID string) (*User, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	row := db.Pool.QueryRow(ctx,
		`SELECT `+userColumns+` FROM users WHERE device_id = $1`, deviceID)
	return scanUser(row)
}

// FindUserByAppleID returns the user matching the given apple_id, or nil if not found.
func (db *DB) FindUserByAppleID(ctx context.Context, appleID string) (*User, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	row := db.Pool.QueryRow(ctx,
		`SELECT `+userColumns+` FROM users WHERE apple_id = $1`, appleID)
	return scanUser(row)
}

// FindUserByVPNUsername returns the user matching the given vpn_username, or nil if not found.
func (db *DB) FindUserByVPNUsername(ctx context.Context, username string) (*User, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	row := db.Pool.QueryRow(ctx,
		`SELECT `+userColumns+` FROM users WHERE vpn_username = $1`, username)
	return scanUser(row)
}

// FindUserByID returns the user matching the given id, or nil if not found.
func (db *DB) FindUserByID(ctx context.Context, id int64) (*User, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	row := db.Pool.QueryRow(ctx,
		`SELECT `+userColumns+` FROM users WHERE id = $1`, id)
	return scanUser(row)
}

// FindUserBySubscriptionToken returns the user matching the given subscription_token, or nil if not found.
func (db *DB) FindUserBySubscriptionToken(ctx context.Context, token string) (*User, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	row := db.Pool.QueryRow(ctx,
		`SELECT `+userColumns+` FROM users WHERE subscription_token = $1`, token)
	return scanUser(row)
}

// FindUserByActivationCode returns the user matching the given activation_code, or nil if not found.
func (db *DB) FindUserByActivationCode(ctx context.Context, code string) (*User, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	row := db.Pool.QueryRow(ctx,
		`SELECT `+userColumns+` FROM users WHERE activation_code = $1`, code)
	return scanUser(row)
}

// CreateUser inserts a new user and populates the ID, CreatedAt, and UpdatedAt fields.
func (db *DB) CreateUser(ctx context.Context, u *User) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	row := db.Pool.QueryRow(ctx, `
		INSERT INTO users (
			telegram_id, username, full_name, is_active, subscription_expiry,
			vpn_username, vpn_uuid, vpn_short_id, auth_provider, apple_id, device_id,
			original_transaction_id, app_store_product_id, ad_source,
			cumulative_traffic, device_limit, phone_number, google_id,
			current_plan, subscription_token, activation_code
		) VALUES (
			$1, $2, $3, $4, $5,
			$6, $7, $8, $9, $10, $11,
			$12, $13, $14,
			$15, $16, $17, $18,
			$19, $20, $21
		)
		RETURNING id, created_at, updated_at`,
		u.TelegramID, u.Username, u.FullName, u.IsActive, u.SubscriptionExpiry,
		u.VPNUsername, u.VPNUUID, u.VPNShortID, u.AuthProvider, u.AppleID, u.DeviceID,
		u.OriginalTransactionID, u.AppStoreProductID, u.AdSource,
		u.CumulativeTraffic, u.DeviceLimit, u.PhoneNumber, u.GoogleID,
		u.CurrentPlan, u.SubscriptionToken, u.ActivationCode,
	)
	return row.Scan(&u.ID, &u.CreatedAt, &u.UpdatedAt)
}

// UpdateUser updates all mutable user fields. The updated_at column is set
// automatically by the database trigger.
func (db *DB) UpdateUser(ctx context.Context, u *User) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	tag, err := db.Pool.Exec(ctx, `
		UPDATE users SET
			telegram_id = $2,
			username = $3,
			full_name = $4,
			is_active = $5,
			subscription_expiry = $6,
			vpn_username = $7,
			vpn_uuid = $8,
			vpn_short_id = $9,
			auth_provider = $10,
			apple_id = $11,
			device_id = $12,
			original_transaction_id = $13,
			app_store_product_id = $14,
			ad_source = $15,
			cumulative_traffic = $16,
			device_limit = $17,
			bot_blocked_at = $18,
			phone_number = $19,
			google_id = $20,
			notified_3d = $21,
			notified_1d = $22,
			current_plan = $23,
			subscription_token = $24,
			activation_code = $25
		WHERE id = $1`,
		u.ID,
		u.TelegramID, u.Username, u.FullName, u.IsActive, u.SubscriptionExpiry,
		u.VPNUsername, u.VPNUUID, u.VPNShortID, u.AuthProvider, u.AppleID, u.DeviceID,
		u.OriginalTransactionID, u.AppStoreProductID, u.AdSource,
		u.CumulativeTraffic, u.DeviceLimit, u.BotBlockedAt, u.PhoneNumber, u.GoogleID,
		u.Notified3D, u.Notified1D, u.CurrentPlan, u.SubscriptionToken, u.ActivationCode,
	)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// DeleteUser soft-deletes a user by setting is_active = false.
func (db *DB) DeleteUser(ctx context.Context, id int64) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	tag, err := db.Pool.Exec(ctx,
		`UPDATE users SET is_active = false WHERE id = $1`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ListActiveVPNUsers returns all active users that have VPN credentials assigned.
func (db *DB) ListActiveVPNUsers(ctx context.Context) ([]User, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	rows, err := db.Pool.Query(ctx, `
		SELECT `+userColumns+`
		FROM users
		WHERE is_active = true
		  AND vpn_uuid IS NOT NULL
		  AND vpn_username IS NOT NULL
		ORDER BY id`)
	if err != nil {
		return nil, err
	}
	return scanUsers(rows)
}

// ListUsers returns a paginated list of users and the total count.
// page is 1-based. pageSize is clamped to [1, 500].
func (db *DB) ListUsers(ctx context.Context, page, pageSize int) ([]User, int64, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	if page < 1 {
		page = 1
	}
	if pageSize < 1 {
		pageSize = 20
	}
	if pageSize > 500 {
		pageSize = 500
	}
	offset := (page - 1) * pageSize

	// Count total rows.
	var total int64
	err := db.Pool.QueryRow(ctx, `SELECT count(*) FROM users`).Scan(&total)
	if err != nil {
		return nil, 0, err
	}

	rows, err := db.Pool.Query(ctx, `
		SELECT `+userColumns+`
		FROM users
		ORDER BY id DESC
		LIMIT $1 OFFSET $2`, pageSize, offset)
	if err != nil {
		return nil, 0, err
	}

	users, err := scanUsers(rows)
	if err != nil {
		return nil, 0, err
	}

	return users, total, nil
}

// UpdateTraffic atomically adds upload and download bytes to the user's cumulative_traffic.
// Uses SELECT ... FOR UPDATE to prevent lost updates under concurrent writes.
func (db *DB) UpdateTraffic(ctx context.Context, vpnUsername string, upload, download int64) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	tx, err := db.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	// Lock the row to prevent concurrent updates from losing data.
	var currentTraffic int64
	err = tx.QueryRow(ctx, `
		SELECT cumulative_traffic
		FROM users
		WHERE vpn_username = $1
		FOR UPDATE`, vpnUsername).Scan(&currentTraffic)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil // User not found, silently skip.
		}
		return err
	}

	_, err = tx.Exec(ctx, `
		UPDATE users
		SET cumulative_traffic = cumulative_traffic + $2
		WHERE vpn_username = $1`,
		vpnUsername, upload+download)
	if err != nil {
		return err
	}

	return tx.Commit(ctx)
}

// SearchUsers returns a paginated list of users matching the search term (by vpn_username or device_id)
// and the total count. page is 1-based. pageSize is clamped to [1, 500].
func (db *DB) SearchUsers(ctx context.Context, search string, page, pageSize int) ([]User, int64, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	if page < 1 {
		page = 1
	}
	if pageSize < 1 {
		pageSize = 20
	}
	if pageSize > 500 {
		pageSize = 500
	}
	offset := (page - 1) * pageSize

	pattern := "%" + search + "%"

	var total int64
	err := db.Pool.QueryRow(ctx, `
		SELECT count(*) FROM users
		WHERE vpn_username ILIKE $1 OR device_id ILIKE $1 OR username ILIKE $1 OR full_name ILIKE $1`,
		pattern).Scan(&total)
	if err != nil {
		return nil, 0, err
	}

	rows, err := db.Pool.Query(ctx, `
		SELECT `+userColumns+`
		FROM users
		WHERE vpn_username ILIKE $1 OR device_id ILIKE $1 OR username ILIKE $1 OR full_name ILIKE $1
		ORDER BY id DESC
		LIMIT $2 OFFSET $3`, pattern, pageSize, offset)
	if err != nil {
		return nil, 0, err
	}

	users, err := scanUsers(rows)
	if err != nil {
		return nil, 0, err
	}

	return users, total, nil
}

// ExtendSubscription extends the user's subscription_expiry by the given number of days.
// If the subscription has already expired, it extends from now.
func (db *DB) ExtendSubscription(ctx context.Context, id int64, days int) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	tag, err := db.Pool.Exec(ctx, `
		UPDATE users SET
			subscription_expiry = GREATEST(COALESCE(subscription_expiry, NOW()), NOW()) + ($2 || ' days')::interval,
			is_active = true
		WHERE id = $1`, id, fmt.Sprintf("%d", days))
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ExtendSubscriptionByUsername extends the user's subscription_expiry by the given number of days, finding by vpn_username.
func (db *DB) ExtendSubscriptionByUsername(ctx context.Context, vpnUsername string, days int) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	tag, err := db.Pool.Exec(ctx, `
		UPDATE users SET
			subscription_expiry = GREATEST(COALESCE(subscription_expiry, NOW()), NOW()) + ($2 || ' days')::interval,
			is_active = true
		WHERE vpn_username = $1`, vpnUsername, fmt.Sprintf("%d", days))
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// DeleteUserByUsername soft-deletes a user by vpn_username, setting is_active = false.
func (db *DB) DeleteUserByUsername(ctx context.Context, vpnUsername string) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	tag, err := db.Pool.Exec(ctx,
		`UPDATE users SET is_active = false WHERE vpn_username = $1`, vpnUsername)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// CountActiveUsers returns the number of active users with VPN credentials.
func (db *DB) CountActiveUsers(ctx context.Context) (int64, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	var count int64
	err := db.Pool.QueryRow(ctx, `
		SELECT count(*) FROM users
		WHERE is_active = true AND vpn_uuid IS NOT NULL AND vpn_username IS NOT NULL`).Scan(&count)
	return count, err
}

// CountTotalUsers returns the total number of users.
func (db *DB) CountTotalUsers(ctx context.Context) (int64, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	var count int64
	err := db.Pool.QueryRow(ctx, `SELECT count(*) FROM users`).Scan(&count)
	return count, err
}

// CountTodayUsers returns the number of users created today.
func (db *DB) CountTodayUsers(ctx context.Context) (int64, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	var count int64
	err := db.Pool.QueryRow(ctx, `
		SELECT count(*) FROM users WHERE created_at >= CURRENT_DATE`).Scan(&count)
	return count, err
}

// TotalTraffic returns total upload + download traffic across all users.
func (db *DB) TotalTraffic(ctx context.Context) (int64, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	var total int64
	err := db.Pool.QueryRow(ctx, `SELECT COALESCE(SUM(cumulative_traffic), 0) FROM users`).Scan(&total)
	return total, err
}

// UsersChangedSince returns all users with vpn_uuid that were updated after the given timestamp.
// Used by cluster sync to exchange user changes between nodes.
func (db *DB) UsersChangedSince(ctx context.Context, since time.Time) ([]User, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	rows, err := db.Pool.Query(ctx, `
		SELECT `+userColumns+`
		FROM users
		WHERE updated_at > $1
		  AND vpn_uuid IS NOT NULL
		ORDER BY updated_at ASC`, since)
	if err != nil {
		return nil, err
	}
	return scanUsers(rows)
}

// FindUserByVPNUUID returns the user matching the given vpn_uuid, or nil if not found.
func (db *DB) FindUserByVPNUUID(ctx context.Context, vpnUUID string) (*User, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	row := db.Pool.QueryRow(ctx,
		`SELECT `+userColumns+` FROM users WHERE vpn_uuid = $1`, vpnUUID)
	return scanUser(row)
}

// UpsertUserByVPNUUID inserts or updates a user identified by vpn_uuid.
// Conflict resolution: the incoming record wins only if its updated_at is newer.
// Returns true if the record was actually inserted or updated.
func (db *DB) UpsertUserByVPNUUID(ctx context.Context, u *User) (bool, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	tag, err := db.Pool.Exec(ctx, `
		INSERT INTO users (
			telegram_id, username, full_name, is_active, subscription_expiry,
			vpn_username, vpn_uuid, vpn_short_id, auth_provider, apple_id, device_id,
			original_transaction_id, app_store_product_id, ad_source,
			cumulative_traffic, device_limit, phone_number, google_id,
			current_plan, subscription_token, activation_code,
			created_at, updated_at
		) VALUES (
			$1, $2, $3, $4, $5,
			$6, $7, $8, $9, $10, $11,
			$12, $13, $14,
			$15, $16, $17, $18,
			$19, $20, $21,
			$22, $23
		)
		ON CONFLICT (vpn_uuid) DO UPDATE SET
			telegram_id = EXCLUDED.telegram_id,
			username = EXCLUDED.username,
			full_name = EXCLUDED.full_name,
			is_active = EXCLUDED.is_active,
			subscription_expiry = EXCLUDED.subscription_expiry,
			vpn_username = EXCLUDED.vpn_username,
			vpn_short_id = EXCLUDED.vpn_short_id,
			auth_provider = EXCLUDED.auth_provider,
			apple_id = EXCLUDED.apple_id,
			device_id = EXCLUDED.device_id,
			original_transaction_id = EXCLUDED.original_transaction_id,
			app_store_product_id = EXCLUDED.app_store_product_id,
			ad_source = EXCLUDED.ad_source,
			cumulative_traffic = EXCLUDED.cumulative_traffic,
			device_limit = EXCLUDED.device_limit,
			phone_number = EXCLUDED.phone_number,
			google_id = EXCLUDED.google_id,
			current_plan = EXCLUDED.current_plan,
			subscription_token = EXCLUDED.subscription_token,
			activation_code = EXCLUDED.activation_code,
			updated_at = EXCLUDED.updated_at
		WHERE users.updated_at < EXCLUDED.updated_at`,
		u.TelegramID, u.Username, u.FullName, u.IsActive, u.SubscriptionExpiry,
		u.VPNUsername, u.VPNUUID, u.VPNShortID, u.AuthProvider, u.AppleID, u.DeviceID,
		u.OriginalTransactionID, u.AppStoreProductID, u.AdSource,
		u.CumulativeTraffic, u.DeviceLimit, u.PhoneNumber, u.GoogleID,
		u.CurrentPlan, u.SubscriptionToken, u.ActivationCode,
		u.CreatedAt, u.UpdatedAt,
	)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}

// InsertTrafficSnapshot records a traffic measurement for the given vpn_username.
func (db *DB) InsertTrafficSnapshot(ctx context.Context, vpnUsername string, upload, download int64) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	_, err := db.Pool.Exec(ctx, `
		INSERT INTO traffic_snapshots (vpn_username, used_traffic, download_traffic, upload_traffic)
		VALUES ($1, $2, $3, $4)`,
		vpnUsername, upload+download, download, upload)
	return err
}
