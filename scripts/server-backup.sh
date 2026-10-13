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
