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

# Cleanup old backups
DELETED=$(find "$BACKUP_DIR" -name "chameleon_*.sql.gz" -mtime +${RETENTION_DAYS} -delete -print 2>/dev/null | wc -l)
[ "$DELETED" -gt 0 ] && echo "[$(date)] Cleaned up $DELETED old backup(s)"

echo "[$(date)] Backup complete"
