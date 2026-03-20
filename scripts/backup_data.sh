#!/bin/bash
set -e

DATE=$(date +%Y-%m-%d)
DEST="/mnt/data/backups/weekly/$DATE"
LOG="/home/kostad/scripts/backup.log"

TARGETS=(
    "/mnt/data/docker/volumes"
    "/opt/stacks"
    "/home/kostad/data"
    "/etc/nginx"
    "/etc/fstab"
)

if ! mountpoint -q /mnt/data; then
    echo "--- [$DATE] ERROR: Backup Drive Not Mounted ---" >> "$LOG"
    exit 1
fi

mkdir -p "$DEST"
echo "--- [$DATE] Backup Session Started ---" >> "$LOG"

for TARGET in "${TARGETS[@]}"; do
    if [ -e "$TARGET" ]; then
        FINAL_DEST="$DEST$(dirname "$TARGET")"
        mkdir -p "$FINAL_DEST"

        if [ -d "$TARGET" ]; then
            rsync -a --delete --exclude='node_modules' "$TARGET/" "$FINAL_DEST/$(basename "$TARGET")/" >> "$LOG" 2>&1
        else
            rsync -a "$TARGET" "$FINAL_DEST/" >> "$LOG" 2>&1
        fi
        echo "[$DATE] Completed: $TARGET" >> "$LOG"
    else
        echo "[$DATE] Skip: $TARGET not found." >> "$LOG"
    fi
done

echo "--- [$DATE] Backup Completed Successfully ---" >> "$LOG"