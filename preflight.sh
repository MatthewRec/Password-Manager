#!/usr/bin/env bash
# ===========================================================================
# preflight.sh - validates this machine is ready to run the Vaultwarden stack.
#
# CHANGES NOTHING. Safe to run as often as you like, before or after deploy.
#
#   ./preflight.sh            normal run
#   ./preflight.sh --verbose  show the value behind each check
#
# Exit codes:  0 = no FAIL rows   1 = one or more FAIL rows
# ===========================================================================

set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

# --- output helpers --------------------------------------------------------
if [[ -t 1 ]]; then
  C_PASS=$'\033[0;32m'; C_WARN=$'\033[0;33m'; C_FAIL=$'\033[0;31m'
  C_HEAD=$'\033[1;36m'; C_DIM=$'\033[2m';    C_OFF=$'\033[0m'
else
  C_PASS=""; C_WARN=""; C_FAIL=""; C_HEAD=""; C_DIM=""; C_OFF=""
fi

N_PASS=0; N_WARN=0; N_FAIL=0
FAILED_ROWS=(); WARNED_ROWS=()

row() {  # row <PASS|WARN|FAIL> <check name> <detail>
  local status="$1" name="$2" detail="${3:-}"
  local colour label
  case "$status" in
    PASS) colour=$C_PASS; label="PASS"; N_PASS=$((N_PASS+1)) ;;
    WARN) colour=$C_WARN; label="WARN"; N_WARN=$((N_WARN+1)); WARNED_ROWS+=("$name - $detail") ;;
    FAIL) colour=$C_FAIL; label="FAIL"; N_FAIL=$((N_FAIL+1)); FAILED_ROWS+=("$name - $detail") ;;
  esac
  printf '  %s%-4s%s  %-38s %s%s%s\n' "$colour" "$label" "$C_OFF" "$name" "$C_DIM" "$detail" "$C_OFF"
}

section() { printf '\n%s%s%s\n' "$C_HEAD" "$1" "$C_OFF"; }
have()    { command -v "$1" >/dev/null 2>&1; }

printf '\n%s=== Vaultwarden preflight =======================================%s\n' "$C_HEAD" "$C_OFF"
printf '%sHost: %s   User: %s   %s%s\n' "$C_DIM" "$(hostname)" "$(whoami)" "$(date -Is)" "$C_OFF"

# ===========================================================================
section "Host"
# ===========================================================================

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) row PASS "Operating system" "${PRETTY_NAME:-$ID}" ;;
    *)                 row WARN "Operating system" "${PRETTY_NAME:-unknown} - written for Debian; should still work" ;;
  esac
else
  row WARN "Operating system" "cannot read /etc/os-release"
fi

if [[ $EUID -eq 0 ]]; then
  row WARN "Running as" "root - works, but a non-root user in the docker group is tidier"
elif id -nG | tr ' ' '\n' | grep -qx docker; then
  row PASS "Running as" "$(whoami) (in docker group)"
else
  row FAIL "Running as" "$(whoami) is not root and not in the docker group"
fi

FREE_MB=$(df -Pm . | awk 'NR==2 {print $4}')
if   [[ $FREE_MB -lt 2048 ]]; then row FAIL "Free disk space" "${FREE_MB}MB - need at least 2GB"
elif [[ $FREE_MB -lt 5120 ]]; then row WARN "Free disk space" "${FREE_MB}MB - thin once attachments and backups accumulate"
else                               row PASS "Free disk space" "${FREE_MB}MB"
fi

# Clock skew breaks TOTP 2FA and TLS. This is a real failure mode, not a nicety.
if have timedatectl; then
  if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes; then
    row PASS "Clock synchronised" "NTP active - TOTP codes will validate"
  else
    row FAIL "Clock synchronised" "NTP not synchronised - TOTP 2FA will reject valid codes"
  fi
else
  row WARN "Clock synchronised" "timedatectl unavailable; verify NTP by hand"
fi

# ===========================================================================
section "Docker"
# ===========================================================================

if have docker; then
  row PASS "docker installed" "$(docker --version 2>/dev/null | head -1)"
  if docker info >/dev/null 2>&1; then
    row PASS "docker daemon reachable" "ok"
  else
    row FAIL "docker daemon reachable" "cannot talk to the daemon - is it running? are you in the docker group?"
  fi
  if docker compose version >/dev/null 2>&1; then
    row PASS "compose plugin" "$(docker compose version --short 2>/dev/null)"
  else
    row FAIL "compose plugin" "'docker compose' unavailable - install docker-compose-plugin"
  fi
else
  row FAIL "docker installed" "not found - install Docker Engine from Docker's apt repo"
fi

if [[ -f docker-compose.yml ]]; then
  row PASS "docker-compose.yml present" "$(pwd)/docker-compose.yml"
  # The whole network model rests on vaultwarden publishing no host port.
  if grep -Eq '^\s*ports:' docker-compose.yml; then
    row WARN "No published host ports" "a 'ports:' stanza exists - confirm it is deliberate"
  else
    row PASS "No published host ports" "vaultwarden is reachable only via cloudflared"
  fi
else
  row FAIL "docker-compose.yml present" "not found in $(pwd)"
fi

# ===========================================================================
section "Configuration (.env)"
# ===========================================================================

if [[ ! -f .env ]]; then
  row FAIL ".env present" "not found - run: cp .env.example .env && chmod 600 .env"
else
  row PASS ".env present" "$(pwd)/.env"

  PERMS=$(stat -c '%a' .env 2>/dev/null || echo "?")
  if [[ "$PERMS" == "600" || "$PERMS" == "400" ]]; then
    row PASS ".env permissions" "$PERMS"
  else
    row FAIL ".env permissions" "$PERMS - contains secrets; run: chmod 600 .env"
  fi

  if [[ -f .gitignore ]] && grep -qx '.env' .gitignore; then
    row PASS ".env is gitignored" "will not be committed"
  else
    row FAIL ".env is gitignored" "NOT ignored - one commit away from publishing your tunnel token"
  fi

  set -a; . ./.env 2>/dev/null; set +a

  check_set() {  # check_set <VAR> <required|optional> [hint]
    local var="$1" need="$2" hint="${3:-}" val="${!1:-}"
    if [[ -z "$val" ]]; then
      [[ "$need" == "required" ]] && row FAIL "$var" "empty - $hint" || row WARN "$var" "empty - $hint"
    elif [[ "$val" == *CHANGEME* ]]; then
      row FAIL "$var" "still the placeholder from .env.example"
    else
      [[ $VERBOSE -eq 1 ]] && row PASS "$var" "$val" || row PASS "$var" "set"
    fi
  }

  check_set DOMAIN       required "public https URL"
  check_set TUNNEL_TOKEN required "from the Cloudflare Zero Trust dashboard"
  check_set ADMIN_TOKEN  required "generate with: docker run --rm -it vaultwarden/server /vaultwarden hash"

  if [[ -n "${DOMAIN:-}" ]]; then
    if [[ "$DOMAIN" == https://* ]]; then
      row PASS "DOMAIN uses https" "$DOMAIN"
    else
      row FAIL "DOMAIN uses https" "$DOMAIN - attachments and WebAuthn break over http"
    fi
    if [[ "$DOMAIN" == */ ]]; then
      row WARN "DOMAIN trailing slash" "remove the trailing slash"
    fi
  fi

  # A plaintext admin token in .env is readable by anything that reads the
  # file or `docker inspect`. The Argon2 hash is not.
  if [[ -n "${ADMIN_TOKEN:-}" && "${ADMIN_TOKEN}" != *CHANGEME* ]]; then
    if [[ "$ADMIN_TOKEN" == \$argon2* ]]; then
      row PASS "ADMIN_TOKEN is hashed" "argon2 PHC string"
    else
      row WARN "ADMIN_TOKEN is hashed" "looks like plaintext - hash it, see README Step 2"
    fi
  fi

  if [[ "${SIGNUPS_ALLOWED:-false}" == "true" ]]; then
    row WARN "SIGNUPS_ALLOWED" "true - anyone reaching the URL can register. Fine briefly; flip back to false."
  else
    row PASS "SIGNUPS_ALLOWED" "false - registration closed"
  fi

  if [[ -z "${SMTP_HOST:-}" ]]; then
    row WARN "SMTP configured" "unset - invitations and email 2FA will not send"
  else
    row PASS "SMTP configured" "${SMTP_HOST}:${SMTP_PORT:-587}"
  fi
fi

# ===========================================================================
section "Network"
# ===========================================================================

if [[ -n "${DOMAIN:-}" ]]; then
  HOSTNAME_ONLY="${DOMAIN#https://}"; HOSTNAME_ONLY="${HOSTNAME_ONLY%%/*}"
  if have getent; then
    if getent hosts "$HOSTNAME_ONLY" >/dev/null 2>&1; then
      row PASS "DNS resolves" "$HOSTNAME_ONLY -> $(getent hosts "$HOSTNAME_ONLY" | awk '{print $1}' | paste -sd, -)"
    else
      row WARN "DNS resolves" "$HOSTNAME_ONLY does not resolve yet - normal until the tunnel's hostname is created"
    fi
  fi
fi

# cloudflared needs outbound 443 only. If this fails, nothing else matters.
if have curl; then
  if curl -sf --max-time 10 -o /dev/null https://api.cloudflare.com/client/v4/ips 2>/dev/null; then
    row PASS "Outbound 443 to Cloudflare" "reachable - tunnel can establish"
  else
    row FAIL "Outbound 443 to Cloudflare" "unreachable - check egress firewall"
  fi
else
  row WARN "Outbound 443 to Cloudflare" "curl not installed; cannot test"
fi

if have ufw; then
  if ufw status 2>/dev/null | grep -qi '^Status: active'; then
    row PASS "Host firewall" "ufw active"
  else
    row WARN "Host firewall" "ufw installed but inactive - enable default-deny inbound"
  fi
else
  row WARN "Host firewall" "ufw not installed - no inbound is required, but deny-by-default is cheap"
fi

if have sshd || [[ -f /etc/ssh/sshd_config ]]; then
  if grep -Eq '^\s*PasswordAuthentication\s+no' /etc/ssh/sshd_config 2>/dev/null; then
    row PASS "SSH password auth disabled" "keys only"
  else
    row WARN "SSH password auth disabled" "password login appears enabled - set PasswordAuthentication no"
  fi
fi

# ===========================================================================
section "Backup prerequisites"
# ===========================================================================

if have sqlite3; then
  row PASS "sqlite3 installed" "$(sqlite3 --version 2>/dev/null | awk '{print $1}')"
else
  row FAIL "sqlite3 installed" "required by backup.sh for a consistent .backup - apt install sqlite3"
fi

case "${BACKUP_ENCRYPTION:-age}" in
  age)
    if have age; then row PASS "age installed" "$(age --version 2>/dev/null)"
    else row FAIL "age installed" "BACKUP_ENCRYPTION=age but age is missing - apt install age"; fi
    if [[ -n "${AGE_RECIPIENT:-}" ]]; then row PASS "AGE_RECIPIENT" "set"
    else row FAIL "AGE_RECIPIENT" "empty - backup.sh cannot encrypt"; fi
    ;;
  gpg)
    if have gpg; then row PASS "gpg installed" "$(gpg --version 2>/dev/null | head -1)"
    else row FAIL "gpg installed" "BACKUP_ENCRYPTION=gpg but gpg is missing"; fi
    if [[ -n "${GPG_PASSPHRASE_FILE:-}" && -r "${GPG_PASSPHRASE_FILE}" ]]; then
      row PASS "GPG_PASSPHRASE_FILE" "readable"
    else
      row FAIL "GPG_PASSPHRASE_FILE" "unset or unreadable"
    fi
    ;;
  none)
    row WARN "Backup encryption" "none - an unencrypted vault archive is a copy of everyone's passwords"
    ;;
esac

if [[ -n "${BACKUP_REMOTE:-}" ]]; then
  row PASS "Off-box backup target" "${BACKUP_REMOTE}"
else
  row WARN "Off-box backup target" "unset - backups stay on the VM they are protecting"
fi

if have rsync; then row PASS "rsync installed" "ok"
else row WARN "rsync installed" "needed to ship backups off-box"; fi

# ===========================================================================
# Summary
# ===========================================================================
printf '\n%s=== Summary =====================================================%s\n' "$C_HEAD" "$C_OFF"
printf '  %sPASS %-3d%s   %sWARN %-3d%s   %sFAIL %-3d%s\n\n' \
  "$C_PASS" "$N_PASS" "$C_OFF" "$C_WARN" "$N_WARN" "$C_OFF" "$C_FAIL" "$N_FAIL" "$C_OFF"

if [[ $N_WARN -gt 0 ]]; then
  printf '%sWarnings (safe to proceed past, but read them):%s\n' "$C_WARN" "$C_OFF"
  for r in "${WARNED_ROWS[@]}"; do printf '  - %s\n' "$r"; done
  printf '\n'
fi

if [[ $N_FAIL -gt 0 ]]; then
  printf '%sFailures (resolve before deploying):%s\n' "$C_FAIL" "$C_OFF"
  for r in "${FAILED_ROWS[@]}"; do printf '  - %s\n' "$r"; done
  printf '\n%sNOT READY.%s\n\n' "$C_FAIL" "$C_OFF"
  exit 1
fi

printf '%sREADY. Next: docker compose up -d%s\n\n' "$C_PASS" "$C_OFF"
exit 0
