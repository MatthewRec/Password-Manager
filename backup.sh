#!/usr/bin/env bash
# ===========================================================================
# backup.sh - consistent, encrypted, off-box backup of the Vaultwarden vault.
#
#   ./backup.sh
#
# Run nightly via the systemd timer in systemd/. Settings come from .env.
#
# Two things here matter more than they look:
#
#  1. The database is captured with sqlite3's .backup command, NOT cp. A live
#     SQLite file copied mid-write yields an archive that restores cleanly and
#     is silently corrupt. You find out during an outage.
#
#  2. rsa_key* and attachments/ are included. They are NOT in the database.
#     Restoring db.sqlite3 alone logs every device out and loses every file
#     attachment - a "successful" restore that has quietly lost data.
# ===========================================================================

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

[[ -f .env ]] || { echo "FATAL: .env not found in $(pwd)" >&2; exit 1; }
set -a; . ./.env; set +a

DATA_DIR="${DATA_DIR:-$(pwd)/vw-data}"
BACKUP_DIR="${BACKUP_DIR:-$(pwd)/backups}"
RETENTION="${BACKUP_RETENTION_DAYS:-14}"
ENCRYPTION="${BACKUP_ENCRYPTION:-age}"
STAMP="$(date +%Y%m%d-%H%M%S)"
NAME="vaultwarden-${STAMP}"

log()   { printf '[%s] %s\n' "$(date -Is)" "$*"; }
fatal() { printf '[%s] FATAL: %s\n' "$(date -Is)" "$*" >&2; exit 1; }

[[ -d "$DATA_DIR" ]] || fatal "data directory not found: $DATA_DIR"
command -v sqlite3 >/dev/null || fatal "sqlite3 not installed"
mkdir -p "$BACKUP_DIR"

WORK="$(mktemp -d)"
# Anything under WORK is plaintext vault data. Remove it on every exit path,
# including failure and Ctrl-C.
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

STAGE="${WORK}/${NAME}"
mkdir -p "$STAGE"
log "staging in $STAGE"

# --- 1. database ------------------------------------------------------------
DB="${DATA_DIR}/db.sqlite3"
if [[ -f "$DB" ]]; then
  log "snapshotting database with sqlite3 .backup"
  sqlite3 "$DB" ".backup '${STAGE}/db.sqlite3'" \
    || fatal "sqlite3 .backup failed"
  # Prove the snapshot is readable before we build an archive around it.
  RESULT="$(sqlite3 "${STAGE}/db.sqlite3" 'PRAGMA integrity_check;' 2>&1)"
  [[ "$RESULT" == "ok" ]] || fatal "integrity_check on the snapshot returned: $RESULT"
  log "integrity_check: ok"
else
  fatal "database not found at $DB (using MySQL/Postgres? adapt this script)"
fi

# --- 2. everything that is not in the database ------------------------------
# rsa_key*  - signs auth tokens; losing it invalidates every active session
# config.json - settings made through the /admin panel
# attachments/, sends/ - files, stored on disk and referenced by the DB
for item in rsa_key rsa_key.pem rsa_key.pub.pem config.json; do
  [[ -e "${DATA_DIR}/${item}" ]] && cp -a "${DATA_DIR}/${item}" "${STAGE}/" && log "included ${item}"
done
for dir in attachments sends; do
  if [[ -d "${DATA_DIR}/${dir}" ]]; then
    cp -a "${DATA_DIR}/${dir}" "${STAGE}/"
    log "included ${dir}/ ($(du -sh "${STAGE}/${dir}" | cut -f1))"
  fi
done

# A manifest makes a restore three years from now far less archaeological.
cat > "${STAGE}/MANIFEST.txt" <<EOF
Vaultwarden backup
Created:   $(date -Is)
Host:      $(hostname)
Source:    ${DATA_DIR}
Image:     $(grep -E '^\s*image:\s*vaultwarden' docker-compose.yml | awk '{print $2}' | head -1)
Contents:  db.sqlite3 (sqlite3 .backup, integrity_check ok), rsa_key*, config.json, attachments/, sends/
Restore:   ./restore.sh <this-archive>
EOF

# --- 3. archive -------------------------------------------------------------
ARCHIVE="${WORK}/${NAME}.tar.gz"
tar -czf "$ARCHIVE" -C "$WORK" "$NAME"
log "archive built ($(du -h "$ARCHIVE" | cut -f1))"

# --- 4. encrypt -------------------------------------------------------------
case "$ENCRYPTION" in
  age)
    [[ -n "${AGE_RECIPIENT:-}" ]] || fatal "BACKUP_ENCRYPTION=age but AGE_RECIPIENT is empty"
    command -v age >/dev/null || fatal "age not installed"
    OUT="${BACKUP_DIR}/${NAME}.tar.gz.age"
    age -r "$AGE_RECIPIENT" -o "$OUT" "$ARCHIVE" || fatal "age encryption failed"
    ;;
  gpg)
    [[ -r "${GPG_PASSPHRASE_FILE:-}" ]] || fatal "GPG_PASSPHRASE_FILE unset or unreadable"
    OUT="${BACKUP_DIR}/${NAME}.tar.gz.gpg"
    gpg --batch --yes --symmetric --cipher-algo AES256 \
        --passphrase-file "$GPG_PASSPHRASE_FILE" \
        --output "$OUT" "$ARCHIVE" || fatal "gpg encryption failed"
    ;;
  none)
    OUT="${BACKUP_DIR}/${NAME}.tar.gz"
    cp "$ARCHIVE" "$OUT"
    log "WARNING: written unencrypted - this file is every password in the vault"
    ;;
  *)
    fatal "unknown BACKUP_ENCRYPTION: $ENCRYPTION (expected age, gpg, or none)"
    ;;
esac

chmod 600 "$OUT"
sha256sum "$OUT" > "${OUT}.sha256"
log "wrote $OUT ($(du -h "$OUT" | cut -f1))"

# --- 5. ship it off the box -------------------------------------------------
# A backup that only exists on the machine it is backing up is not a backup.
if [[ -n "${BACKUP_REMOTE:-}" ]]; then
  command -v rsync >/dev/null || fatal "rsync not installed but BACKUP_REMOTE is set"
  log "shipping to ${BACKUP_REMOTE}"
  rsync -a --partial "$OUT" "${OUT}.sha256" "$BACKUP_REMOTE" \
    || fatal "off-box copy FAILED - local copy kept at $OUT"
  log "off-box copy ok"
else
  log "WARNING: BACKUP_REMOTE unset - this backup lives only on the VM it protects"
fi

# --- 6. retention -----------------------------------------------------------
DELETED=$(find "$BACKUP_DIR" -maxdepth 1 -name 'vaultwarden-*.tar.gz*' \
            -mtime "+${RETENTION}" -print -delete | wc -l)
[[ "$DELETED" -gt 0 ]] && log "pruned ${DELETED} archive(s) older than ${RETENTION} days"

log "done: $(basename "$OUT")"
