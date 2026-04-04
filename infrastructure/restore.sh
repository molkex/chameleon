#!/usr/bin/env bash
# ============================================================
#  Chameleon VPN — Restore from backup
#  Usage: sudo ./restore.sh /backups/chameleon/db_20260404.dump
# ============================================================
set -euo pipefail

DUMP_FILE="${1:?Usage: ./restore.sh <path-to-dump>}"
[[ -f "$DUMP_FILE" ]] || { echo "File not found: $DUMP_FILE"; exit 1; }

echo "Restoring from: $DUMP_FILE"
echo "WARNING: This will overwrite the current database!"
read -rp "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0

# Stop backend to prevent writes during restore
docker compose stop backend 2>/dev/null || true

# Restore
docker exec -i chameleon-postgres pg_restore -U chameleon -d chameleon --clean --if-exists < "$DUMP_FILE"

# Restart
docker compose up -d backend

echo "Restore complete. Backend restarting..."
