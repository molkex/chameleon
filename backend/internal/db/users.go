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
	last_seen, last_ip, last_user_agent, app_version, os_name, os_version,
	last_country, last_country_name, last_city,
	initial_ip, initial_country, initial_country_name, initial_city,
	timezone, device_model, ios_version, accept_language, install_date, store_country,
	email, email_verified_at, password_hash,
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
		&u.LastSeen, &u.LastIP, &u.LastUserAgent, &u.AppVersion, &u.OSName, &u.OSVersion,
		&u.LastCountry, &u.LastCountryName, &u.LastCity,
		&u.InitialIP, &u.InitialCountry, &u.InitialCountryName, &u.InitialCity,
		&u.Timezone, &u.DeviceModel, &u.IOSVersion, &u.AcceptLanguage, &u.InstallDate, &u.StoreCountry,
		&u.Email, &u.EmailVerifiedAt, &u.PasswordHash,
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
			&u.LastSeen, &u.LastIP, &u.LastUserAgent, &u.AppVersion, &u.OSName, &u.OSVersion,
			&u.LastCountry, &u.LastCountryName, &u.LastCity,
			&u.InitialIP, &u.InitialCountry, &u.InitialCountryName, &u.InitialCity,
			&u.Timezone, &u.DeviceModel, &u.IOSVersion, &u.AcceptLanguage, &u.InstallDate, &u.StoreCountry,
			&u.Email, &u.EmailVerifiedAt, &u.PasswordHash,
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

// FindUserByGoogleID returns the user matching the given google_id, or nil
// if not found. Used by /auth/google to decide between login and signup.
func (db *DB) FindUserByGoogleID(ctx context.Context, googleID string) (*User, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	row := db.Pool.QueryRow(ctx,
		`SELECT `+userColumns+` FROM users WHERE google_id = $1`, googleID)
	return scanUser(row)
}

// FindUserByOriginalTransactionID looks up a user by their Apple
// originalTransactionId — the stable id we persist on first IAP purchase.
// Used by the ASN v2 webhook to route renewals to the right user.
func (db *DB) FindUserByOriginalTransactionID(ctx context.Context, otxID string) (*User, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	row := db.Pool.QueryRow(ctx,
		`SELECT `+userColumns+` FROM users WHERE original_transaction_id = $1`, otxID)
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
//
// If the direct lookup misses, FindUserByID falls back to id_aliases —
// historical id values from the now-retired NL multi-master backend (and from
// race-registration dedup) map to their canonical users.id row there. This
// transparently keeps iOS clients with stale JWTs in Keychain working after
// the federated cluster was consolidated to single-master DE on 2026-04-25.
//
// Single hop only: id_aliases.real_id is FK-constrained to users.id, so a
// follow-up alias chain is structurally impossible.
func (db *DB) FindUserByID(ctx context.Context, id int64) (*User, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	row := db.Pool.QueryRow(ctx,
		`SELECT `+userColumns+` FROM users WHERE id = $1`, id)
	u, err := scanUser(row)
	if err != nil || u != nil {
		return u, err
	}

	row = db.Pool.QueryRow(ctx,
		`SELECT `+userColumns+`
		 FROM users
		 WHERE id = (SELECT real_id FROM id_aliases WHERE alt_id = $1)`, id)
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

// SetUserEmail stores the receipt email on the user row. Called during the
// payment initiate flow so FreeKassa gets a real email for the 54-FZ receipt
// and the admin panel can see which address a user registered with.
func (db *DB) SetUserEmail(ctx context.Context, id int64, email string) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	tag, err := db.Pool.Exec(ctx,
		`UPDATE users SET email = $2 WHERE id = $1`, id, email)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ClearDeviceID nulls out the device_id for the given user. Used when claiming
// a device_id that's currently associated with a different (e.g. transient
// guest) user — required to avoid UNIQUE(device_id) collision when an existing
// authenticated user signs in on a fresh install where a guest row was created.
func (db *DB) ClearDeviceID(ctx context.Context, id int64) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	_, err := db.Pool.Exec(ctx,
		`UPDATE users SET device_id = NULL WHERE id = $1`, id)
	return err
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

// WipeUserOnDelete is a stronger form of DeleteUser for the self-service
// "Delete Account" flow. In addition to flipping is_active=false, it nulls
// out subscription/config/device state so that if the user comes back via
// Apple Sign-In the row reactivates as a blank slate — no lingering Pro
// status, no stale VPN credentials. The user must restore purchases or buy
// again to regain premium access, and will be re-assigned fresh VPN creds.
// The row itself is retained for audit and for receipt replay (Apple IAP
// notifications can still land on the original_transaction_id).
func (db *DB) WipeUserOnDelete(ctx context.Context, id int64) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	tag, err := db.Pool.Exec(ctx,
		`UPDATE users SET
			is_active = false,
			subscription_expiry = NULL,
			vpn_username = NULL,
			vpn_uuid = NULL,
			vpn_short_id = NULL,
			device_id = NULL,
			current_plan = NULL,
			subscription_token = NULL
		 WHERE id = $1`, id)
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

// maxSearchLen caps the search term length so that an attacker cannot pass
// a megabyte string and force expensive ILIKE scans.
const maxSearchLen = 100

// SearchUsers returns a paginated list of users matching the search term (by vpn_username or device_id)
// and the total count. page is 1-based. pageSize is clamped to [1, 500].
// search is truncated to maxSearchLen characters.
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
	if len(search) > maxSearchLen {
		search = search[:maxSearchLen]
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

// DeviceInfo is the set of client/location fields refreshed each time a user
// fetches their VPN config. Empty strings leave the existing value unchanged
// so callers can fill in what they know without wiping prior data.
type DeviceInfo struct {
	IP             string
	UserAgent      string
	AppVersion     string
	OSName         string
	OSVersion      string
	Country        string
	CountryName    string
	City           string
	Timezone       string
	DeviceModel    string
	IOSVersion     string
	AcceptLanguage string
}

// TouchUserDevice bumps last_seen to NOW() and overlays any non-empty fields
// from info onto the user's device/location columns.
func (db *DB) TouchUserDevice(ctx context.Context, userID int64, info DeviceInfo) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	_, err := db.Pool.Exec(ctx, `
		UPDATE users SET
			last_seen         = NOW(),
			last_ip           = CASE WHEN $2  = '' THEN last_ip           ELSE $2  END,
			last_user_agent   = CASE WHEN $3  = '' THEN last_user_agent   ELSE $3  END,
			app_version       = CASE WHEN $4  = '' THEN app_version       ELSE $4  END,
			os_name           = CASE WHEN $5  = '' THEN os_name           ELSE $5  END,
			os_version        = CASE WHEN $6  = '' THEN os_version        ELSE $6  END,
			last_country      = CASE WHEN $7  = '' THEN last_country      ELSE $7  END,
			last_country_name = CASE WHEN $8  = '' THEN last_country_name ELSE $8  END,
			last_city         = CASE WHEN $9  = '' THEN last_city         ELSE $9  END,
			timezone          = CASE WHEN $10 = '' THEN timezone          ELSE $10 END,
			device_model      = CASE WHEN $11 = '' THEN device_model      ELSE $11 END,
			ios_version       = CASE WHEN $12 = '' THEN ios_version       ELSE $12 END,
			accept_language   = CASE WHEN $13 = '' THEN accept_language   ELSE $13 END
		WHERE id = $1`,
		userID, info.IP, info.UserAgent, info.AppVersion, info.OSName, info.OSVersion,
		info.Country, info.CountryName, info.City,
		info.Timezone, info.DeviceModel, info.IOSVersion, info.AcceptLanguage)
	return err
}

// InitialContext is the snapshot saved at registration time. Only populated
// once per user — we use COALESCE so repeat /auth/register calls don't
// overwrite the original signup country once it's been captured.
type InitialContext struct {
	IP          string
	Country     string
	CountryName string
	City        string
	InstallDate *time.Time
}

// SaveInitialContext writes the signup snapshot iff the relevant columns are
// still empty. Safe to call on every /auth/register hit.
func (db *DB) SaveInitialContext(ctx context.Context, userID int64, c InitialContext) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	_, err := db.Pool.Exec(ctx, `
		UPDATE users SET
			initial_ip           = CASE WHEN initial_ip           = '' THEN $2 ELSE initial_ip           END,
			initial_country      = CASE WHEN initial_country      = '' THEN $3 ELSE initial_country      END,
			initial_country_name = CASE WHEN initial_country_name = '' THEN $4 ELSE initial_country_name END,
			initial_city         = CASE WHEN initial_city         = '' THEN $5 ELSE initial_city         END,
			install_date         = COALESCE(install_date, $6)
		WHERE id = $1`,
		userID, c.IP, c.Country, c.CountryName, c.City, c.InstallDate)
	return err
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
