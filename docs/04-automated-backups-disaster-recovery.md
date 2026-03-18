<h1> 0.4 Automated Backups & Disaster Recovery</h1>

This guide implements a multi-layered backup strategy designed for high availability and data integrity. By combining **Btrfs snapshots** for system-level rollbacks and **Versioned Rsync mirroring** with automated pruning, we ensure that every administrative error has a documented "Undo" button.

> [!IMPORTANT]
> **The Golden Rule:** A backup is not a backup until you have tested the restore process. If you just let scripts run without checking them, you are gambling with your system data.

- [System Snapshots (Btrfs)](#system-snapshots-btrfs)
  - [1. Install Snapper](#1-install-snapper)
  - [2. Initial Configuration](#2-initial-configuration)
- [Data Backups (Cron + Rsync)](#data-backups-cron--rsync)
  - [1. Environment Setup](#1-environment-setup)
  - [2. The Defensive Backup Script](#2-the-defensive-backup-script)
- [Automated Cleanup (The Janitor)](#automated-cleanup-the-janitor)
  - [Permissions](#permissions)
- [Validation \& Testing](#validation--testing)
  - [1. Manual Execution](#1-manual-execution)
  - [2. Pruning Simulation](#2-pruning-simulation)
- [Scheduling \& Automation](#scheduling--automation)
  - [Define the Schedule](#define-the-schedule)
- [Summary](#summary)

## System Snapshots (Btrfs)

Since the operating system resides on a Btrfs partition (`sda2`), we leverage its copy-on-write (CoW) capabilities to take instantaneous snapshots. These consume zero additional space until files are modified.

### 1. Install Snapper

Snapper is the industry-standard tool for managing Btrfs snapshots on Arch Linux.

```bash
sudo pacman -S snapper
```

### 2. Initial Configuration

Create a configuration profile for the root partition:

```bash
sudo snapper -c root create-config /
```

## Data Backups (Cron + Rsync)

To protect against physical SSD failure, critical data is mirrored to the secondary drive (`/mnt/data`). We use a defensive, array-driven script to ensure the process is logged and resilient.

### 1. Environment Setup

Install the scheduler and synchronization utilities:

```bash
sudo pacman -S cronie rsync
sudo systemctl enable --now cronie
sudo systemctl enable --now snapper-cleanup.timer
```

### 2. The Defensive Backup Script

This script uses an array-based architecture to sync specific folders while gracefully skipping missing ones.

`vim ~/scripts/backup_data.sh`

```bash
#!/bin/bash
set -e

DATE=$(date +%Y-%m-%d)
DEST="/mnt/data/backups/weekly/$DATE"
LOG="/home/kostad/scripts/backup.log"

TARGETS=(
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
```

## Automated Cleanup (The Janitor)

To prevent the drive from filling up with obsolete versions, we use a pruning script to delete backups older than 60 days.

`vim ~/scripts/prune_backups.sh`

```bash
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
```

### Permissions

Ensure the script is executable:

```bash
chmod +x ~/scripts/backup_data.sh ~/scripts/prune_backups.sh
```

## Validation & Testing

Verify your "Undo" button works before you actually need it.

### 1. Manual Execution

Run the backup manually and check for "Permission Denied" or path errors in the log.

```bash
~/scripts/backup_data.sh
cat ~/scripts/backup.log
```

### 2. Pruning Simulation

Create a fake, backdated folder to ensure the Janitor accurately identifies and removes expired backups.

```bash
mkdir -p /mnt/data/backups/weekly/2020-01-01
touch -d "2020-01-01" /mnt/data/backups/weekly/2020-01-01
~/scripts/prune_backups.sh
ls /mnt/data/backups/weekly/
```

## Scheduling & Automation

We utilize `cronie` to execute the backup and cleanup tasks during _low-traffic_ hours.

### Define the Schedule

Open the crontab editor:

```bash
sudo crontab -e
```

Add the following entries (Backup at 02:00, Pruning at 03:00 every Sunday):

```text
0 2 * * 0 /home/kostad/scripts/backup_data.sh
0 3 * * 0 /home/kostad/scripts/prune_backups.sh
```

## Summary

This architecture provides a **self-healing data lifecycle**. You now have system-level rollbacks via Btrfs, off-disk data redundancy via Rsync, and automated storage management via the pruning script.

Have fun!
