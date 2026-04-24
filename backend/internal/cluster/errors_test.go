package cluster

import (
	"errors"
	"fmt"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

// TestIsDuplicateVPNUsername guards the SQLSTATE-23505 detection that
// demotes expected vpn_username collisions during cluster sync from error
// to warn. The matcher must match BOTH the unique_violation code AND the
// constraint name so we don't silence other unique violations.
func TestIsDuplicateVPNUsername(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{
			name: "nil error",
			err:  nil,
			want: false,
		},
		{
			name: "plain error",
			err:  errors.New("boom"),
			want: false,
		},
		{
			name: "wrapped plain error",
			err:  fmt.Errorf("upsert failed: %w", errors.New("boom")),
			want: false,
		},
		{
			name: "pg error wrong code",
			err:  &pgconn.PgError{Code: "42P01", ConstraintName: "idx_users_vpn_username"},
			want: false,
		},
		{
			name: "pg error 23505 wrong constraint",
			err:  &pgconn.PgError{Code: "23505", ConstraintName: "users_pkey"},
			want: false,
		},
		{
			name: "pg error 23505 vpn_username constraint (index name)",
			err:  &pgconn.PgError{Code: "23505", ConstraintName: "idx_users_vpn_username"},
			want: true,
		},
		{
			name: "pg error 23505 vpn_username constraint (table_col form)",
			err:  &pgconn.PgError{Code: "23505", ConstraintName: "users_vpn_username_key"},
			want: true,
		},
		{
			name: "wrapped pg error matches via errors.As",
			err:  fmt.Errorf("upsert: %w", &pgconn.PgError{Code: "23505", ConstraintName: "idx_users_vpn_username"}),
			want: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := isDuplicateVPNUsername(tc.err)
			if got != tc.want {
				t.Errorf("isDuplicateVPNUsername(%v): want %v, got %v", tc.err, tc.want, got)
			}
		})
	}
}

// TestSafeDeref verifies the nil-safe helper used in cluster sync logging.
func TestSafeDeref(t *testing.T) {
	if got := safeDeref(nil); got != "<nil>" {
		t.Errorf("safeDeref(nil): want <nil>, got %q", got)
	}
	v := "abc"
	if got := safeDeref(&v); got != "abc" {
		t.Errorf("safeDeref(&\"abc\"): want abc, got %q", got)
	}
}
