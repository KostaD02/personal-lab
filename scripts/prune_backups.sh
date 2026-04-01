#!/bin/bash
set -e

BACKUP_DIR="/mnt/data/backups/weekly"
RETENTION_DAYS=60
LOG="/home/kostad/scripts/backup.log"

echo "--- [$(date +%Y-%m-%d)] Starting Backup Pruning ---" >> "$LOG"

if mountpoint -q /mnt/data; then
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +$RETENTION_DAYS -exec rm -rf {} + >> "$LOG" 2>&1

    echo "--- [$(date +%Y-%m-%d)] Pruning Completed ---" >> "$LOG"
else
    echo "--- [$(date +%Y-%m-%d)] Prune Failed: Drive not mounted ---" >> "$LOG"
    exit 1
fi