#!/usr/bin/env bash
# ============================================================
#  Chameleon VPN — Restore Postgres from a backup
# ============================================================
# Backups are produced by backend/scripts/db-backup.sh as PLAIN pg_dump
# piped through gzip (chameleon_YYYYMMDD_HHMMSS.sql.gz), kept locally in
# /var/backups/chameleon and pushed off-host to Backblaze B2.
#
# Usage (run on the NL box, from the backend/ dir that holds docker-compose.yml):
#   sudo ./restore.sh /var/backups/chameleon/chameleon_20260621_030000.sql.gz
#   sudo ./restore.sh --from-b2 chameleon_20260621_030000.sql.gz   # pull from B2 first
#   sudo ./restore.sh --list-b2                                    # list available B2 backups
#
# PRODUCT-MATURITY-LOOP D2 (2026-06-21): the previous restore.sh ran
#   pg_restore --clean --if-exists < "$DUMP_FILE"
# expecting a custom-format (-Fc) dump and stopped a service called "backend".
# But the real production backups are PLAIN gzipped SQL — pg_restore CANNOT
# read them — and the backend compose service is named "chameleon", not
# "backend". So the ONLY documented disaster-recovery path did not work
# against the actual backups, on the single NL DB node. This rewrite consumes
# *.sql.gz (gunzip | psql), can pull from B2, recreates the DB so a plain dump
# (no --clean) restores cleanly, and aborts on the first SQL error.
set -euo pipefail

CONTAINER="chameleon-postgres"
DB_NAME="chameleon"
DB_USER="chameleon"
COMPOSE_SERVICE="chameleon"          # the Go backend service in docker-compose.yml
B2_REMOTE="b2-madfrog:madfrog-vpn-backups/postgres"
RCLONE_CONF="/root/.config/rclone/rclone.conf"

die() { echo "ERROR: $*" >&2; exit 1; }
rclone_b2() { rclone --config "$RCLONE_CONF" "$@"; }

# ── --list-b2 ──────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--list-b2" ]]; then
    command -v rclone >/dev/null 2>&1 || die "rclone not installed"
    [[ -f "$RCLONE_CONF" ]] || die "rclone config not found at $RCLONE_CONF"
    echo "Available B2 backups (newest last):"
    rclone_b2 lsf "$B2_REMOTE/" | sort
    exit 0
fi

DUMP_FILE=""
# ── --from-b2 <name> ───────────────────────────────────────────────────────
if [[ "${1:-}" == "--from-b2" ]]; then
    NAME="${2:?Usage: ./restore.sh --from-b2 <backup-filename.sql.gz>}"
    command -v rclone >/dev/null 2>&1 || die "rclone not installed"
    [[ -f "$RCLONE_CONF" ]] || die "rclone config not found at $RCLONE_CONF"
    TMPDIR_DL="$(mktemp -d)"
    echo "Pulling $NAME from B2..."
    rclone_b2 copy "$B2_REMOTE/$NAME" "$TMPDIR_DL/" || die "B2 pull failed for $NAME"
    DUMP_FILE="$TMPDIR_DL/$NAME"
    [[ -f "$DUMP_FILE" ]] || die "downloaded file missing: $DUMP_FILE"
else
    DUMP_FILE="${1:?Usage: ./restore.sh <path-to-backup.sql.gz> | --from-b2 <name> | --list-b2}"
fi

[[ -f "$DUMP_FILE" ]] || die "File not found: $DUMP_FILE"
docker inspect "$CONTAINER" >/dev/null 2>&1 || die "Postgres container '$CONTAINER' not running"

echo "Restoring from: $DUMP_FILE"
echo "WARNING: this DROPs and RECREATEs the '$DB_NAME' database — all current data is replaced."
read -rp "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# Stop the backend so nothing writes mid-restore. --no-deps so we never touch
# postgres/redis/singbox dependencies.
echo ">>> Stopping backend ($COMPOSE_SERVICE)..."
docker compose stop "$COMPOSE_SERVICE" 2>/dev/null || docker stop "$COMPOSE_SERVICE" 2>/dev/null || true

# Recreate the target DB. The plain dumps carry no DROP/CREATE (pg_dump without
# --clean), so restoring into the live DB would collide on every existing
# object. Drop+recreate from the 'postgres' maintenance DB after terminating
# any lingering connections. (DB_USER is the postgres-image superuser.)
echo ">>> Recreating database '$DB_NAME'..."
docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d postgres <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS ${DB_NAME};
CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};
SQL

# Restore by format. Default + production path is plain gzipped SQL.
echo ">>> Restoring data..."
case "$DUMP_FILE" in
    *.sql.gz)
        gunzip -c "$DUMP_FILE" | docker exec -i "$CONTAINER" \
            psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME"
        ;;
    *.sql)
        docker exec -i "$CONTAINER" \
            psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" < "$DUMP_FILE"
        ;;
    *.dump|*.fc|*.pgdump)
        # Legacy custom-format (-Fc) dumps from the old infrastructure/backup.sh.
        docker exec -i "$CONTAINER" \
            pg_restore -U "$DB_USER" -d "$DB_NAME" --no-owner < "$DUMP_FILE"
        ;;
    *)
        die "Unrecognized backup format: $DUMP_FILE (expected *.sql.gz, *.sql, or *.dump)"
        ;;
esac

# Restart the backend.
echo ">>> Restarting backend ($COMPOSE_SERVICE)..."
docker compose up -d --no-deps "$COMPOSE_SERVICE" 2>/dev/null || docker start "$COMPOSE_SERVICE" 2>/dev/null || true

echo "✓ Restore complete. Verify: docker exec -it $CONTAINER psql -U $DB_USER -d $DB_NAME -c '\\dt' | head"
