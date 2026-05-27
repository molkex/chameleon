#!/bin/bash
# PostgreSQL backup — daily, retain 7 days
# Cron: 0 3 * * * /path/to/db-backup.sh >> /var/log/chameleon-backup.log 2>&1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="/var/backups/chameleon"
CONTAINER="chameleon-postgres"
DB_NAME="chameleon"
DB_USER="chameleon"
RETENTION_DAYS=7
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/chameleon_${TIMESTAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

echo "[$(date)] Starting backup..."

docker exec "$CONTAINER" pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$BACKUP_FILE"

# Verify backup is not empty
FILESIZE=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE" 2>/dev/null || echo 0)
if [ "$FILESIZE" -lt 100 ]; then
    echo "[$(date)] ERROR: Backup file too small (${FILESIZE} bytes)"
    if [ -f "$SCRIPT_DIR/telegram-alert.sh" ]; then
        HOSTNAME=$(hostname -f 2>/dev/null || hostname)
        "$SCRIPT_DIR/telegram-alert.sh" "🔴 <b>$HOSTNAME</b>: DB backup FAILED (${FILESIZE} bytes)"
    fi
    exit 1
fi

echo "[$(date)] Backup created: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"

# Push to Backblaze B2 off-host (added 2026-05-27). The local backup above
# is the primary safety net; B2 is the redundancy against a total node loss
# (Timeweb failure, disk death, accidental rm -rf, etc). B2 retention is
# kept LONGER than local (30 days vs 7) so a delayed corruption discovery
# can still be recovered from B2 after the local copy is gone.
#
# Failure here is NOT fatal: local backup already succeeded — the script
# returns 0 and a Telegram alert flags the failure so it gets attention.
if command -v rclone >/dev/null 2>&1 && [ -f /root/.config/rclone/rclone.conf ] && grep -q "^\[b2-madfrog\]" /root/.config/rclone/rclone.conf; then
    B2_PATH="b2-madfrog:madfrog-vpn-backups/postgres/"
    if rclone --config /root/.config/rclone/rclone.conf copy "$BACKUP_FILE" "$B2_PATH" 2>&1; then
        echo "[$(date)] Pushed to B2: $B2_PATH$(basename "$BACKUP_FILE")"

        # Cleanup B2 — older than 30 days. Done via `rclone delete --min-age`
        # rather than per-file lifecycle on the bucket so retention lives in
        # one place (this script) and can be changed without B2 console
        # access.
        B2_DELETED=$(rclone --config /root/.config/rclone/rclone.conf delete --min-age 30d "$B2_PATH" 2>&1 | grep -c "INFO.*Deleted" || true)
        [ "$B2_DELETED" -gt 0 ] && echo "[$(date)] B2 cleaned up $B2_DELETED old backup(s)"
    else
        echo "[$(date)] WARNING: B2 push failed (local backup still OK)"
        if [ -f "$SCRIPT_DIR/telegram-alert.sh" ]; then
            HOSTNAME=$(hostname -f 2>/dev/null || hostname)
            "$SCRIPT_DIR/telegram-alert.sh" "🟡 <b>$HOSTNAME</b>: B2 off-host backup push failed (local backup OK; check rclone logs)"
        fi
    fi
else
    echo "[$(date)] B2 off-host push skipped (rclone or config missing)"
fi

# Cleanup old local backups
DELETED=$(find "$BACKUP_DIR" -name "chameleon_*.sql.gz" -mtime +${RETENTION_DAYS} -delete -print 2>/dev/null | wc -l)
[ "$DELETED" -gt 0 ] && echo "[$(date)] Cleaned up $DELETED old local backup(s)"

echo "[$(date)] Backup complete"
