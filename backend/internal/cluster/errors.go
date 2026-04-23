package cluster

import (
	"errors"
	"strings"

	"github.com/jackc/pgx/v5/pgconn"
)

// isDuplicateVPNUsername returns true when err is a Postgres unique-constraint
// violation on idx_users_vpn_username. Used to demote noisy expected sync
// conflicts (vpn_username collides because it's deterministic on device_id —
// re-registering after delete reuses the same username with a new vpn_uuid)
// from error to warn, so real failures stay visible in dashboards.
func isDuplicateVPNUsername(err error) bool {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return false
	}
	if pgErr.Code != "23505" { // unique_violation
		return false
	}
	return strings.Contains(pgErr.ConstraintName, "users_vpn_username")
}
