package db

import "context"

// SetUserTheme updates the user's ui_theme column. Returns ErrNotFound if the user does not exist.
func (db *DB) SetUserTheme(ctx context.Context, userID int64, theme string) error {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	tag, err := db.Pool.Exec(ctx,
		`UPDATE users SET ui_theme = $2 WHERE id = $1`, userID, theme)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// ThemeDistribution returns a map of theme name → user count (for admin analytics).
func (db *DB) ThemeDistribution(ctx context.Context) (map[string]int64, error) {
	ctx, cancel := defaultTimeout(ctx)
	defer cancel()

	rows, err := db.Pool.Query(ctx,
		`SELECT ui_theme, COUNT(*) FROM users GROUP BY ui_theme`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make(map[string]int64)
	for rows.Next() {
		var theme string
		var count int64
		if err := rows.Scan(&theme, &count); err != nil {
			return nil, err
		}
		out[theme] = count
	}
	return out, rows.Err()
}
