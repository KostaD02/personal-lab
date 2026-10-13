<h1> 0.4 Automated Backups & Disaster Recovery</h1>

This guide implements a backup strategy that is **verified by restore**, not by exit code. It combines **engine-level database dumps**, **SQLite online snapshots**, and **hardlinked rsync sets** on a **separate physical disk**, scheduled by **systemd**. Every run either produces a complete set and promotes it to `latest`, or moves itself aside as `FAILED_*` so a half backup can never be mistaken for a real one.

> [!IMPORTANT]
> **The Golden Rule:** A backup is not a backup until you have tested the restore process. If you just let scripts run without checking them, you are gambling with your system data.

> [!WARNING]
> **The Lesson:** The first version of this guide used a cron job running as my normal user. Docker volumes are owned by root with mode `0710`, so the script could not even enter the directory. Its `[ -e ]` check reported "not found", it skipped every target, and then logged **"Backup Completed Successfully"** 26 weeks in a row. For more than two months there was no backup at all. Everything below exists because of that.

- [Design Principles](#design-principles)
- [System Snapshots (Btrfs)](#system-snapshots-btrfs)
- [Environment Setup](#environment-setup)
- [The Backup Script](#the-backup-script)
  - [1. Create the script](#1-create-the-script)
  - [2. What each phase does](#2-what-each-phase-does)
  - [3. Configuration](#3-configuration)
  - [4. What is NOT backed up](#4-what-is-not-backed-up)
- [Scheduling via Systemd](#scheduling-via-systemd)
  - [1. The service](#1-the-service)
  - [2. The timer](#2-the-timer)
  - [3. Enable and verify](#3-enable-and-verify)
- [Validation \& Testing](#validation--testing)
  - [1. Manual Execution](#1-manual-execution)
  - [2. Restore Test (Postgres)](#2-restore-test-postgres)
  - [3. Restore Test (SQLite)](#3-restore-test-sqlite)
  - [4. Pruning Simulation](#4-pruning-simulation)
- [Disaster Recovery](#disaster-recovery)
  - [Restore a Postgres database](#restore-a-postgres-database)
  - [Restore a SQLite database](#restore-a-sqlite-database)
  - [Restore a volume directory](#restore-a-volume-directory)
  - [Restore the package list](#restore-the-package-list)
- [Summary](#summary)

## Design Principles

| Principle                   | Why                                                                                                                    |
| :-------------------------- | :--------------------------------------------------------------------------------------------------------------------- |
| **Different physical disk** | Docker data lives on the HDD (`sdb1`). Backups go to the SSD (`sda2`). A copy on the same disk dies with the disk.     |
| **Run as root**             | Docker volumes are root-owned. Anything else silently skips them (see the lesson above).                               |
| **Dump through the engine** | A file copy of a running Postgres/Mongo data directory is not reliably restorable. `pg_dumpall` and `mongodump` are.   |
| **Hardlink against `latest`** | `rsync --link-dest` means unchanged files cost zero bytes. The first run copies everything, every run after only what changed.  |
| **Promote only on success** | `latest` only moves when every phase passed. Partial sets are renamed `FAILED_*` and never used as a link source.      |
| **Prune never eats `latest`** | Retention is by count, and the set `latest` points at is always kept, even if it is the oldest.                       |

## System Snapshots (Btrfs)

> [!NOTE]
> **Optional:** I keep this section for completeness, but snapper is currently `disabled` on my server. The rsync sets below are the real backup; snapshots are a convenience "Undo" for the root partition.

Since the operating system resides on a Btrfs partition (`sda2`), we can leverage its copy-on-write (CoW) capabilities to take instantaneous snapshots. These consume zero additional space until files are modified.

```bash
sudo pacman -S snapper
sudo snapper -c root create-config /
sudo systemctl enable --now snapper-cleanup.timer
```

## Environment Setup

`rsync` copies the file trees, `sqlite3` takes consistent snapshots of the many small `.db` files that self-hosted apps love (vaultwarden, homarr, n8n, jellyfin, the \*arr suite). Docker is already installed from [01-arch-installation.md](01-arch-installation.md).

```bash
sudo pacman -S rsync sqlite
```

Create the destination on the **SSD**, readable by root only:

```bash
sudo mkdir -p /var/backups/server
sudo chmod 700 /var/backups/server
```

## The Backup Script

### 1. Create the script

`sudo vim /usr/local/sbin/server-backup.sh`

```bash
#!/usr/bin/env bash
# /usr/local/sbin/server-backup.sh - runs as root via systemd timer.
#
# Destination is /var/backups/server on sda2 - a DIFFERENT physical disk
# from the data it protects (/mnt/data on sdb1).
#
# NOT COVERED: /mnt/data/media. It does not fit on any disk in this
# machine. A file manifest is stored instead, and every run says so out loud.

set -uo pipefail

BACKUP_ROOT="/var/backups/server"
LOG="/var/log/server-backup.log"
VOLUMES="/mnt/data/docker/volumes"
MEDIA="/mnt/data/media"
KEEP=8
KEEP_FAILED=2
MIN_FREE_GB=60

TARGETS=(
  "volumes:/mnt/data/docker/volumes"
  "stacks:/opt/stacks"
  "home:/home/kostad"
  "etc:/etc"
  "root:/root"
)

EXCLUDES=(
  --exclude='node_modules/'
  --exclude='lost+found/'
  --exclude='*.sock'
  # anything holding credentials you do not want inside a backup set
  --exclude='YOUR_PRIVATE_DIR/'
)

STATUS_SET=0
rc_total=0

ts(){ date +'%F %T'; }
log(){ printf '%s %s\n' "$(ts)" "$*" | tee -a "$LOG"; }
die(){ log "ABORT: $*"; printf 'FAILED %s :: %s\n' "$(ts)" "$*" > "$BACKUP_ROOT/STATUS"; STATUS_SET=1; exit 1; }

# envof <container> <VAR> -> value of VAR inside that container's environment
STATUS_JSON="/opt/stacks/.backup-status.json"

# Machine-readable result for n8n to poll. /opt/stacks is bind-mounted
# read-only into the n8n container, so n8n can read this but cannot alter it.
write_status_json(){
  printf '{"result":"%s","finished":"%s","epoch":%s,"host":"%s","set":"%s","size":"%s","store":"%s","db_dumps":%s,"sqlite_ok":%s,"sqlite_failed":%s,"sqlite_skipped":%s}\n' \
    "$1" "$(date -Is)" "$(date +%s)" "$(cat /etc/hostname 2>/dev/null || echo "${HOSTNAME:-unknown}")" "${FAILED_DEST:-${DEST:-unknown}}" \
    "${SIZE:-unknown}" "${STORE:-unknown}" "${found_db:-0}" "${sq_ok:-0}" "${sq_bad:-0}" "${sq_skip:-0}" \
    > "$STATUS_JSON" 2>/dev/null || true
  chmod 644 "$STATUS_JSON" 2>/dev/null || true
}

envof(){ docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null | sed -n "s/^$2=//p" | head -1; }

mkdir -p "$BACKUP_ROOT" || { echo "cannot create $BACKUP_ROOT"; exit 1; }
chmod 700 "$BACKUP_ROOT"

on_exit(){
  local rc=$?
  [ "$rc" -eq 0 ] && return 0
  [ "$STATUS_SET" -eq 1 ] && return 0
  printf 'FAILED %s :: unexpected exit %s\n' "$(ts)" "$rc" > "$BACKUP_ROOT/STATUS"
  return 0
}
trap on_exit EXIT

exec 9>/run/lock/server-backup.lock
flock -n 9 || { echo "a backup is already running"; exit 1; }

# ---------- preconditions ----------
[ "$(id -u)" -eq 0 ] || die "must run as root - this is why the old script could never read Docker volumes"
mountpoint -q /mnt/data || die "/mnt/data is NOT mounted - refusing to back up an empty directory"
[ -d "$VOLUMES" ] || die "$VOLUMES is missing or unreadable"

AVAIL=$(df -BG --output=avail "$BACKUP_ROOT" | tail -1 | tr -dc '0-9')
[ "${AVAIL:-0}" -ge "$MIN_FREE_GB" ] || die "only ${AVAIL}G free at $BACKUP_ROOT, need ${MIN_FREE_GB}G"

LATEST="$BACKUP_ROOT/latest"
DEST="$BACKUP_ROOT/$(date +%F)"
[ -e "$DEST" ] && DEST="${DEST}_$(date +%H%M)"
mkdir -p "$DEST/_db" || die "cannot create $DEST"

log "=== backup start -> $DEST ==="
log "NOT INCLUDED: $MEDIA - no disk in this machine can hold it"

# ---------- 1. consistent dumps from every running database container ----------
# A file-level copy of a running Postgres/MySQL/Mongo data directory is not
# reliably restorable. Dump through the engine first, then copy files.
# Discovery is by image name so a database added later cannot be silently missed.
found_db=0
while IFS=$'\t' read -r c img; do
  [ -n "$c" ] || continue
  case "$img" in
    *postgres*|*timescale*|*pgvector*|*vectorchord*)
      u="$(envof "$c" POSTGRES_USER)"; u="${u:-postgres}"
      out="$DEST/_db/${c}.sql.gz"
      # no -t: a TTY would corrupt the stream with CRLF
      if docker exec "$c" pg_dumpall --clean --if-exists -U "$u" 2>>"$LOG" | gzip > "$out" \
         && zcat "$out" | tail -5 | grep 'dump complete' >/dev/null; then
        log "DB OK (postgres): $c -> $(du -h "$out" | cut -f1)"; found_db=1
      else
        log "DB ERROR (postgres): $c dump failed or truncated"; rc_total=1
      fi
      ;;
    *mariadb*|*mysql*)
      rp="$(envof "$c" MYSQL_ROOT_PASSWORD)"
      out="$DEST/_db/${c}.sql.gz"
      if docker exec -e MYSQL_PWD="$rp" "$c" mysqldump -u root --all-databases --single-transaction --quick 2>>"$LOG" | gzip > "$out" \
         && zcat "$out" | tail -5 | grep -i 'dump completed' >/dev/null; then
        log "DB OK (mysql): $c -> $(du -h "$out" | cut -f1)"; found_db=1
      else
        log "DB ERROR (mysql): $c dump failed or truncated"; rc_total=1
      fi
      ;;
    *mongo*)
      mu="$(envof "$c" MONGO_INITDB_ROOT_USERNAME)"
      mp="$(envof "$c" MONGO_INITDB_ROOT_PASSWORD)"
      margs=()
      [ -n "$mu" ] && margs+=(--username "$mu" --authenticationDatabase admin)
      [ -n "$mp" ] && margs+=(--password "$mp")
      out="$DEST/_db/${c}.archive.gz"
      err="$DEST/_db/${c}.dump.log"
      # no -t/-i: the archive is binary on stdout and a TTY would corrupt it.
      # An empty gzip is ~20 bytes and still passes gzip -t, hence the size floor
      # and the 'done dumping' marker as well.
      if docker exec "$c" mongodump --archive --gzip "${margs[@]}" >"$out" 2>"$err" \
         && gzip -t "$out" 2>/dev/null \
         && grep -q 'done dumping' "$err" \
         && [ "$(stat -c %s "$out")" -gt 4096 ]; then
        log "DB OK (mongo): $c -> $(du -h "$out" | cut -f1)"; found_db=1
      else
        log "DB ERROR (mongo): $c dump failed, truncated or empty (see $err)"; rc_total=1
      fi
      cat "$err" >>"$LOG" 2>/dev/null
      ;;
  esac
done < <(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null)

[ "$found_db" -eq 1 ] || { log "DB ERROR: no database dumps were produced at all"; rc_total=1; }

# ---------- 2. SQLite online snapshots ----------
# A live .db plus its -wal/-shm sidecars copied by rsync can restore malformed.
# sqlite3 .backup takes a consistent snapshot through the engine instead.
if command -v sqlite3 >/dev/null 2>&1; then
  mkdir -p "$DEST/_db/sqlite"
  sq_ok=0; sq_bad=0; sq_skip=0
  while IFS= read -r -d '' db; do
    # BoltDB (filebrowser, docker metadata.db) and H2 (.mv.db) also use .db.
    # Every real SQLite file begins with these 15 bytes; trust that, not the name.
    if [ "$(head -c 15 "$db" 2>/dev/null | tr -d "\\0")" != "SQLite format 3" ]; then
      sq_skip=$((sq_skip+1)); continue
    fi
    rel="${db#"$VOLUMES"/}"
    tgt="$DEST/_db/sqlite/${rel//\//__}"
    # .backup writes a consistent snapshot; integrity_check proves it is readable
    if sqlite3 "$db" ".backup '$tgt'" 2>>"$LOG" \
       && [ "$(sqlite3 "$tgt" 'PRAGMA integrity_check;' 2>>"$LOG")" = "ok" ]; then
      sq_ok=$((sq_ok+1))
    else
      sq_bad=$((sq_bad+1)); log "SQLITE WARN: could not snapshot or verify $db"
      rm -f -- "$tgt"
    fi
  done < <(find "$VOLUMES" -maxdepth 6 \
             -path "$VOLUMES/YOUR_PRIVATE_DIR" -prune -o \
             \( -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) \
                -size -2G \) -print0 2>/dev/null)
  log "sqlite snapshots: $sq_ok ok, $sq_bad failed, $sq_skip skipped (not SQLite)"
  [ "$sq_ok" -gt 0 ] || log "SQLITE WARN: no SQLite databases were snapshotted"
else
  log "SQLITE WARN: sqlite3 not installed - live SQLite DBs are copied as raw files only (pacman -S sqlite)"
fi

# ---------- 3. file trees, hardlinked against the previous successful run ----------
for entry in "${TARGETS[@]}"; do
  name="${entry%%:*}"; path="${entry#*:}"
  if [ ! -d "$path" ]; then
    log "ERROR: $path missing or unreadable"; rc_total=1; continue
  fi
  linkopt=()
  if [ -d "$LATEST/$name" ]; then
    linkopt=(--link-dest="$(readlink -f "$LATEST")/$name")
  fi
  rsync -aHAX --numeric-ids "${EXCLUDES[@]}" "${linkopt[@]}" "$path/" "$DEST/$name/" >>"$LOG" 2>&1
  rc=$?
  case "$rc" in
    0|24) log "OK: $path" ;;
    *)    log "ERROR: rsync exit $rc on $path"; rc_total=1 ;;
  esac
done

# sanity: the largest dataset must actually be present
[ -d "$DEST/volumes/immich/library" ] || { log "ERROR: immich library missing from backup set"; rc_total=1; }

# ---------- 4. media is not backed up; record what exists so losses are knowable ----------
find "$MEDIA" -type f -printf '%s\t%p\n' 2>/dev/null | gzip > "$DEST/_media-manifest.tsv.gz"
log "media manifest: $(zcat "$DEST/_media-manifest.tsv.gz" | wc -l) files recorded (files NOT backed up)"

if command -v pacman >/dev/null 2>&1; then
  pacman -Qqe > "$DEST/_pacman-explicit.txt" 2>/dev/null \
    && log "package list: $(wc -l < "$DEST/_pacman-explicit.txt") explicit packages recorded"
fi

# ---------- 5. promote only on full success ----------
SIZE=$(du -sh "$DEST" 2>/dev/null | cut -f1)
if [ "$rc_total" -eq 0 ]; then
  printf 'complete %s\nsize %s\n' "$(ts)" "$SIZE" > "$DEST/_COMPLETE"
  ln -sfn "$DEST" "$LATEST"
  printf 'OK %s :: %s (%s)\n' "$(ts)" "$DEST" "$SIZE" > "$BACKUP_ROOT/STATUS"
  STATUS_SET=1
  log "=== backup OK: $DEST ($SIZE) ==="
else
  # move aside so a partial set can never be mistaken for a backup,
  # nor be picked up as a link-dest source or by the 20* prune glob
  FAILED_DEST="$BACKUP_ROOT/FAILED_$(basename "$DEST")_$(date +%H%M%S)"
  if mv -T -- "$DEST" "$FAILED_DEST" 2>>"$LOG"; then
    log "=== backup INCOMPLETE: moved aside to $FAILED_DEST, NOT promoted ==="
  else
    FAILED_DEST="$DEST"
    log "=== backup INCOMPLETE: $DEST NOT promoted (move aside failed) ==="
  fi
  printf 'FAILED %s :: %s incomplete\n' "$(ts)" "$FAILED_DEST" > "$BACKUP_ROOT/STATUS"
  STATUS_SET=1
fi

# ---------- 6. prune: runs regardless, but never removes the last good backup ----------
keep_real=""
[ -L "$LATEST" ] && keep_real="$(basename "$(readlink -f "$LATEST")")"

mapfile -t sets < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' -printf '%f\n' 2>/dev/null | sort)
if [ "${#sets[@]}" -gt "$KEEP" ]; then
  for old in "${sets[@]:0:$(( ${#sets[@]} - KEEP ))}"; do
    if [ "$old" = "$keep_real" ]; then
      log "prune: KEEPING $old (last good backup)"; continue
    fi
    log "prune: removing $old"
    rm -rf -- "${BACKUP_ROOT:?}/${old:?}"
  done
fi

mapfile -t bad < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'FAILED_20*' -printf '%f\n' 2>/dev/null | sort)
if [ "${#bad[@]}" -gt "$KEEP_FAILED" ]; then
  for old in "${bad[@]:0:$(( ${#bad[@]} - KEEP_FAILED ))}"; do
    log "prune: removing failed set $old"
    rm -rf -- "${BACKUP_ROOT:?}/${old:?}"
  done
fi

STORE="$(du -sh "$BACKUP_ROOT" 2>/dev/null | cut -f1)"
log "total backup store: $STORE"
if [ "$rc_total" -eq 0 ]; then write_status_json OK; else write_status_json FAILED; fi
log "status file: $STATUS_JSON"
[ "$rc_total" -eq 0 ] || exit 1
exit 0
```

Make it executable by root only:

```bash
sudo chmod 750 /usr/local/sbin/server-backup.sh
```

### 2. What each phase does

| Phase                  | What happens                                                                                                                                                                   |
| :--------------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Preconditions**      | Refuses to run unless it is root, `/mnt/data` is really mounted, the volumes directory exists, and the SSD has at least `MIN_FREE_GB` free. A lock file prevents overlapping runs. |
| **1. Database dumps**  | Looks at `docker ps` and dumps every Postgres, MySQL/MariaDB and Mongo container it finds. Discovery is by image name, so a database you add next month is picked up automatically. Each dump is checked for its "dump complete" marker. |
| **2. SQLite snapshots** | Finds every `.db` / `.sqlite` file under the volumes, checks the 15-byte `SQLite format 3` header (BoltDB and H2 also use `.db`), takes an online `.backup`, and runs `PRAGMA integrity_check` on the result. |
| **3. File trees**      | `rsync -aHAX` of every `TARGETS` entry into the new set, hardlinked against `latest` so unchanged files are free. Exit code `24` (file vanished during copy) is tolerated, anything else fails the run. |
| **4. Manifests**       | A gzip'd list of every media file (size + path) and the explicit pacman package list. Media is not copied, but you will know exactly what was lost.                              |
| **5. Promote**         | If every phase passed: write `_COMPLETE`, point `latest` at the new set, write `STATUS` and a machine-readable status JSON. Otherwise rename the set to `FAILED_*` and leave `latest` alone.     |
| **6. Prune**           | Keep the newest `KEEP` good sets and `KEEP_FAILED` failed sets. The set `latest` points at is never deleted.                                                                     |

### 3. Configuration

| Variable      | Default                 | Description                                                                                |
| :------------ | :---------------------- | :----------------------------------------------------------------------------------------- |
| `BACKUP_ROOT` | `/var/backups/server`   | Destination. Must be on a different disk than the data.                                    |
| `KEEP`        | `8`                     | Number of good sets to keep. With hardlinks, 8 sets cost roughly 1 full copy plus changes. |
| `KEEP_FAILED` | `2`                     | Number of `FAILED_*` sets to keep for debugging.                                           |
| `MIN_FREE_GB` | `60`                    | Abort before starting if the destination has less free space than this.                   |
| `TARGETS`     | volumes, stacks, home, etc, root | `name:path` pairs. The name becomes the folder inside the set.                   |
| `EXCLUDES`    | node_modules, lost+found, sockets, `YOUR_PRIVATE_DIR` | Passed straight to rsync. Put any directory that holds credentials you do not want inside a backup set here. |

### 4. What is NOT backed up

> [!IMPORTANT]
> `/mnt/data/media` (X TB) is not backed up. It does not fit on any disk in this machine, and it is re-downloadable. The script says so in the log on **every** run, and stores a manifest so a loss is at least knowable. If that ever changes, add `"media:/mnt/data/media"` to `TARGETS` and point `BACKUP_ROOT` at a disk that can hold it.

There is also **no offsite copy** yet. A dead motherboard or a fire takes both disks. That is a known gap, not an oversight.

## Scheduling via Systemd

Cron is gone. A systemd timer gives us `Persistent=true` (a missed 02:00 run executes at next boot), `RequiresMountsFor` (no run against an unmounted `/mnt/data`), journal logging, and a start timeout that fits a full backup.

### 1. The service

`sudo vim /etc/systemd/system/server-backup.service`

```ini
[Unit]
Description=Server backup to /var/backups/server (separate physical disk)
Requires=docker.service
After=docker.service
RequiresMountsFor=/mnt/data

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/server-backup.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
TimeoutStartSec=4h
```

| Option                  | Description                                                                                                        |
| :---------------------- | :----------------------------------------------------------------------------------------------------------------- |
| **Requires / After**    | Docker must be up, otherwise `docker ps` finds nothing and phase 1 fails.                                          |
| **RequiresMountsFor**   | The unit will not start if `/mnt/data` is not mounted.                                                             |
| **Nice / IOScheduling** | Lowest-priority CPU and disk so Jellyfin and friends do not notice the backup running.                             |
| **TimeoutStartSec=4h**  | **Crucial.** The systemd default is 90 seconds. A full first run takes far longer than that and would have been killed.     |

### 2. The timer

`sudo vim /etc/systemd/system/server-backup.timer`

```ini
[Unit]
Description=Daily server backup

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
RandomizedDelaySec=300
Unit=server-backup.service

[Install]
WantedBy=timers.target
```

| Option                   | Description                                                                              |
| :----------------------- | :--------------------------------------------------------------------------------------- |
| **OnCalendar**           | Every day at 02:00.                                                                      |
| **Persistent**           | If the server was off at 02:00, the run happens as soon as it boots.                     |
| **RandomizedDelaySec**   | Up to 5 minutes of jitter, so it does not collide with other 02:00 jobs to the second.   |

### 3. Enable and verify

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now server-backup.timer
systemctl list-timers server-backup.timer
```

You should see the `NEXT` column pointing at the coming 02:00.

## Validation & Testing

Verify your "Undo" button works before you actually need it.

### 1. Manual Execution

Run the service by hand and watch it:

```bash
sudo systemctl start server-backup.service
journalctl -u server-backup -f
```

When it finishes, check the result from every angle:

```bash
cat /var/backups/server/STATUS
ls -la /var/backups/server
tail -40 /var/log/server-backup.log
```

You should see `OK` in `STATUS`, a `latest` symlink pointing at today's set, and a `_db` folder with one `.sql.gz` per Postgres container.

### 2. Restore Test (Postgres)

A dump that "looks fine" proves nothing. Restore it into a throwaway container and compare row counts with the live database.

```bash
docker run -d --name restore-test -e POSTGRES_PASSWORD=test postgres:15
sleep 5
zcat /var/backups/server/latest/_db/kan-db.sql.gz | docker exec -i restore-test psql -U postgres
```

Count rows in every table on both sides and diff:

```bash
Q="SELECT schemaname||'.'||relname, n_live_tup FROM pg_stat_user_tables ORDER BY 1;"
docker exec kan-db       psql -U kan      -d kan_db -Atc "$Q" > /tmp/live.txt
docker exec restore-test psql -U postgres -d kan_db -Atc "$Q" > /tmp/restored.txt
diff /tmp/live.txt /tmp/restored.txt && echo "RESTORE OK"
docker rm -f restore-test
```

No output from `diff` means every table came back with the same number of rows.

### 3. Restore Test (SQLite)

Snapshots live under `_db/sqlite/` with the path flattened (`/` becomes `__`). Compare one against the live file:

```bash
ls /var/backups/server/latest/_db/sqlite/
sqlite3 /var/backups/server/latest/_db/sqlite/vaultwarden__db.sqlite3 .dump > /tmp/snap.sql
sqlite3 /mnt/data/docker/volumes/vaultwarden/db.sqlite3 .dump > /tmp/live.sql
diff /tmp/snap.sql /tmp/live.sql && echo "SNAPSHOT OK"
```

### 4. Pruning Simulation

Retention is by count, not age. Create more fake sets than `KEEP` and confirm the oldest go while `latest` stays:

```bash
for d in 2020-01-0{1..9}; do sudo mkdir -p /var/backups/server/$d; done
sudo systemctl start server-backup.service
ls /var/backups/server/
```

The `2020-*` folders should be gone and the set behind `latest` untouched. Check the log for `prune: KEEPING` lines.

## Disaster Recovery

The scenarios below assume the SSD survived and `/var/backups/server/latest` is readable. If the SSD is the thing that died, you first reinstall Arch from [01-arch-installation.md](01-arch-installation.md) and restore the package list, `/etc` and `/opt/stacks` from the newest set you can find.

### Restore a Postgres database

Stop the app (not the database), load the dump, start the app:

```bash
cd /opt/stacks/workspace/kan
docker compose stop web
zcat /var/backups/server/latest/_db/kan-db.sql.gz | docker exec -i kan-db psql -U kan -d postgres
docker compose start web
```

`pg_dumpall --clean --if-exists` drops and recreates every database, so this replaces whatever is in the container.

### Restore a SQLite database

Stop the container, copy the snapshot over the live file, remove stale sidecars, start again:

```bash
cd /opt/stacks/utility/vaultwarden
docker compose stop
sudo cp /var/backups/server/latest/_db/sqlite/vaultwarden__db.sqlite3 /mnt/data/docker/volumes/vaultwarden/db.sqlite3
sudo rm -f /mnt/data/docker/volumes/vaultwarden/db.sqlite3-wal /mnt/data/docker/volumes/vaultwarden/db.sqlite3-shm
docker compose start
```

### Restore a volume directory

For everything that is not a database (configs, uploads, the Immich library):

```bash
cd /opt/stacks/media/immich
docker compose stop
sudo rsync -aHAX --delete /var/backups/server/latest/volumes/immich/ /mnt/data/docker/volumes/immich/
docker compose start
```

> [!CAUTION]
> `--delete` makes the live directory identical to the backup. Anything created after the backup is gone. Drop the flag if you only want to fill in missing files.

### Restore the package list

After a fresh install, bring back every package you had explicitly installed:

```bash
sudo pacman -S --needed - < /var/backups/server/latest/_pacman-explicit.txt
```

## Summary

This architecture replaces a backup that **claimed** success with one that **proves** it.

- **Data Layer**: Databases are dumped through their own engines and SQLite files are snapshotted online, so every copy is restorable, not just present.
- **Storage Layer**: Sets live on a different physical disk, hardlinked against each other, so eight generations cost about one full copy.
- **Integrity Layer**: A set is promoted to `latest` only when every phase passed. Partial sets are quarantined as `FAILED_*`, and pruning can never delete the last good one.
- **Scheduling Layer**: A systemd timer with `Persistent=true` and a 4-hour timeout, so missed nights are caught up and long runs are not killed.

Have fun!
