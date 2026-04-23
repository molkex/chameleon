package db

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
)

// adminColumns lists all columns for the admin_users table.
const adminColumns = `id, username, password_hash, role, is_active, last_login, created_at`

// FindAdminByUsername returns the admin user matching the given username, or nil if not found.
// Only returns active admins.
func (db *DB) FindAdminByUsername(ctx context.Context, username string) (*AdminUser, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	var a AdminUser
	err := db.Pool.QueryRow(ctx, `
		SELECT `+adminColumns+`
		FROM admin_users
		WHERE username = $1 AND is_active = true`, username).Scan(
		&a.ID, &a.Username, &a.PasswordHash, &a.Role, &a.IsActive, &a.LastLogin, &a.CreatedAt,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &a, nil
}

// FindAdminByID returns the admin user matching the given id, or nil if not found.
func (db *DB) FindAdminByID(ctx context.Context, id int64) (*AdminUser, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	var a AdminUser
	err := db.Pool.QueryRow(ctx, `
		SELECT `+adminColumns+`
		FROM admin_users
		WHERE id = $1 AND is_active = true`, id).Scan(
		&a.ID, &a.Username, &a.PasswordHash, &a.Role, &a.IsActive, &a.LastLogin, &a.CreatedAt,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &a, nil
}

// UpdateAdminLastLogin updates the last_login timestamp for the given admin.
func (db *DB) UpdateAdminLastLogin(ctx context.Context, id int64) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	_, err := db.Pool.Exec(ctx, `
		UPDATE admin_users SET last_login = NOW() WHERE id = $1`, id)
	return err
}

// UpdateAdminPasswordHash updates the password hash for the given admin.
// Used for rehashing legacy passwords (bcrypt/SHA-256 -> argon2id).
func (db *DB) UpdateAdminPasswordHash(ctx context.Context, id int64, hash string) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	_, err := db.Pool.Exec(ctx, `
		UPDATE admin_users SET password_hash = $2 WHERE id = $1`, id, hash)
	return err
}

// ListAdmins returns all admin users.
func (db *DB) ListAdmins(ctx context.Context) ([]AdminUser, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	rows, err := db.Pool.Query(ctx, `
		SELECT `+adminColumns+`
		FROM admin_users
		WHERE is_active = true
		ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var admins []AdminUser
	for rows.Next() {
		var a AdminUser
		err := rows.Scan(&a.ID, &a.Username, &a.PasswordHash, &a.Role, &a.IsActive, &a.LastLogin, &a.CreatedAt)
		if err != nil {
			return nil, err
		}
		admins = append(admins, a)
	}
	return admins, rows.Err()
}

// CreateAdmin creates a new admin user.
func (db *DB) CreateAdmin(ctx context.Context, username, passwordHash, role string) (*AdminUser, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	var a AdminUser
	err := db.Pool.QueryRow(ctx, `
		INSERT INTO admin_users (username, password_hash, role, is_active)
		VALUES ($1, $2, $3, true)
		RETURNING `+adminColumns,
		username, passwordHash, role).Scan(
		&a.ID, &a.Username, &a.PasswordHash, &a.Role, &a.IsActive, &a.LastLogin, &a.CreatedAt,
	)
	if err != nil {
		return nil, err
	}
	return &a, nil
}

// DeleteAdmin soft-deletes an admin user.
func (db *DB) DeleteAdmin(ctx context.Context, id int64) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	tag, err := db.Pool.Exec(ctx, `
		UPDATE admin_users SET is_active = false WHERE id = $1`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
