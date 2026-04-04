#!/usr/bin/env bash
# ============================================================
#  Chameleon VPN — Automated backup
#  Backs up PostgreSQL + .env to a remote server or local path.
#
#  Usage:
#    ./backup.sh                    # Local backup to /backups/
#    ./backup.sh user@remote:/path  # Remote backup via rsync
#
#  Cron (daily at 3am):
#    0 3 * * * /path/to/chameleon/infrastructure/backup.sh >> /var/log/chameleon-backup.log 2>&1
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${BACKUP_DIR:-/backups/chameleon}"
REMOTE_TARGET="${1:-}"
DATE=$(date +%Y%m%d_%H%M%S)

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

# 1. Dump PostgreSQL
log "Dumping PostgreSQL..."
docker exec chameleon-postgres pg_dump -U chameleon -Fc chameleon > "$BACKUP_DIR/db_${DATE}.dump"
log "DB dump: $(du -h "$BACKUP_DIR/db_${DATE}.dump" | cut -f1)"

# 2. Backup .env (encrypted)
log "Backing up .env..."
cp "$PROJECT_DIR/.env" "$BACKUP_DIR/env_${DATE}.bak"
chmod 600 "$BACKUP_DIR/env_${DATE}.bak"

# 3. Cleanup old backups (keep last 7 days)
find "$BACKUP_DIR" -name "db_*.dump" -mtime +7 -delete 2>/dev/null || true
find "$BACKUP_DIR" -name "env_*.bak" -mtime +7 -delete 2>/dev/null || true

# 4. Sync to remote if specified
if [[ -n "$REMOTE_TARGET" ]]; then
    log "Syncing to $REMOTE_TARGET..."
    rsync -az --delete "$BACKUP_DIR/" "$REMOTE_TARGET"
    log "Remote sync complete"
fi

log "Backup complete: $BACKUP_DIR/db_${DATE}.dump"
