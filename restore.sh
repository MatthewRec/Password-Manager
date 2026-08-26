#!/usr/bin/env bash
# ===========================================================================
# restore.sh - restore a Vaultwarden backup produced by backup.sh.
#
#   ./restore.sh /path/to/vaultwarden-20260826-030000.tar.gz.age
#   ./restore.sh <archive> --dry-run    unpack and verify, touch nothing
#
# Run this on a THROWAWAY VM at least once a quarter (README Step 7). An
# untested backup is a hypothesis, not a backup.
#
# On a real restore this stops the stack, moves the existing vw-data aside
# (it is never deleted), unpacks the archive in its place, and starts again.
# ===========================================================================

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

ARCHIVE="${1:-}"
DRY_RUN=0
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ -z "$ARCHIVE" ]]; then
  echo "usage: $0 <archive> [--dry-run]" >&2
  exit 1
fi
[[ -f "$ARCHIVE" ]] || { echo "FATAL: no such archive: $ARCHIVE" >&2; exit 1; }

[[ -f .env ]] || { echo "FATAL: .env not found in $(pwd)" >&2; exit 1; }
set -a; . ./.env; set +a

DATA_DIR="${DATA_DIR:-$(pwd)/vw-data}"

log()   { printf '[%s] %s\n' "$(date -Is)" "$*"; }
fatal() { printf '[%s] FATAL: %s\n' "$(date -Is)" "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# --- 1. checksum ------------------------------------------------------------
if [[ -f "${ARCHIVE}.sha256" ]]; then
  log "verifying checksum"
  ( cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "${ARCHIVE}.sha256")" ) \
    || fatal "checksum mismatch - archive is damaged"
  log "checksum ok"
else
  log "WARNING: no .sha256 alongside the archive; skipping integrity check"
fi

# --- 2. decrypt -------------------------------------------------------------
TARBALL="${WORK}/restore.tar.gz"
case "$ARCHIVE" in
  *.age)
    command -v age >/dev/null || fatal "age not installed"
    KEY="${AGE_IDENTITY_FILE:-$HOME/.age/vaultwarden.key}"
    [[ -r "$KEY" ]] || fatal "age identity not readable at $KEY (set AGE_IDENTITY_FILE)"
    log "decrypting with age"
    age -d -i "$KEY" -o "$TARBALL" "$ARCHIVE" || fatal "decryption failed"
    ;;
  *.gpg)
    [[ -r "${GPG_PASSPHRASE_FILE:-}" ]] || fatal "GPG_PASSPHRASE_FILE unset or unreadable"
    log "decrypting with gpg"
    gpg --batch --yes --decrypt --passphrase-file "$GPG_PASSPHRASE_FILE" \
        --output "$TARBALL" "$ARCHIVE" || fatal "decryption failed"
    ;;
  *.tar.gz)
    log "archive is unencrypted"
    cp "$ARCHIVE" "$TARBALL"
    ;;
  *)
    fatal "unrecognised archive type: $ARCHIVE"
    ;;
esac

# --- 3. unpack and verify ---------------------------------------------------
tar -xzf "$TARBALL" -C "$WORK" || fatal "extraction failed"
# A glob rather than `find | head -1`: under `set -o pipefail`, head closing
# the pipe early can fail the whole pipeline and abort the restore.
SRC=""
for d in "$WORK"/vaultwarden-*/; do
  [[ -d "$d" ]] && { SRC="${d%/}"; break; }
done
[[ -n "$SRC" ]] || fatal "archive does not contain a vaultwarden-* directory"

command -v sqlite3 >/dev/null || fatal "sqlite3 not installed - needed to verify the restore"

[[ -f "${SRC}/db.sqlite3" ]] || fatal "no db.sqlite3 in the archive"
RESULT="$(sqlite3 "${SRC}/db.sqlite3" 'PRAGMA integrity_check;' 2>&1)"
[[ "$RESULT" == "ok" ]] || fatal "restored database fails integrity_check: $RESULT"
log "database integrity_check: ok"

USERS=$(sqlite3 "${SRC}/db.sqlite3" 'SELECT COUNT(*) FROM users;' 2>/dev/null || echo '?')
ITEMS=$(sqlite3 "${SRC}/db.sqlite3" 'SELECT COUNT(*) FROM ciphers;' 2>/dev/null || echo '?')
log "archive contains ${USERS} user account(s) and ${ITEMS} vault item(s)"

if [[ -f "${SRC}/MANIFEST.txt" ]]; then
  echo "--- MANIFEST ---"; cat "${SRC}/MANIFEST.txt"; echo "----------------"
fi

for item in rsa_key rsa_key.pem; do
  [[ -e "${SRC}/${item}" ]] && { log "rsa_key present - existing sessions will survive"; break; }
done

if [[ $DRY_RUN -eq 1 ]]; then
  log "DRY RUN - archive is valid and restorable. Nothing on this host was changed."
  exit 0
fi

# --- 4. commit --------------------------------------------------------------
echo
echo "About to replace ${DATA_DIR} with the contents of this archive."
echo "The current directory will be MOVED aside, not deleted."
read -r -p "Type RESTORE to continue: " CONFIRM
[[ "$CONFIRM" == "RESTORE" ]] || { log "aborted"; exit 1; }

if command -v docker >/dev/null && docker compose ps -q 2>/dev/null | grep -q .; then
  log "stopping stack"
  docker compose down
fi

if [[ -d "$DATA_DIR" ]]; then
  ASIDE="${DATA_DIR}.pre-restore-$(date +%Y%m%d-%H%M%S)"
  mv "$DATA_DIR" "$ASIDE"
  log "previous data moved to ${ASIDE}"
fi

mkdir -p "$DATA_DIR"
cp -a "${SRC}/." "${DATA_DIR}/"
rm -f "${DATA_DIR}/MANIFEST.txt"
chmod 700 "$DATA_DIR"
log "data restored to ${DATA_DIR}"

log "starting stack"
docker compose up -d

echo
log "Restore complete. Now actually verify it:"
echo "  1. docker compose ps          - both containers up"
echo "  2. log in from a browser extension and confirm items decrypt"
echo "  3. record the date and outcome in README.md under 'Restore drill log'"
