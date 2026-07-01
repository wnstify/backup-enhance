#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)
DB_RUNNER_SOURCE="$SCRIPT_DIR/enhance-db-backup.sh"
FILES_RUNNER_SOURCE="$SCRIPT_DIR/enhance-files-backup.sh"
LIB_RUNNER_SOURCE="$SCRIPT_DIR/enhance-backup-lib.sh"
DB_INSTALL_BIN=/usr/local/sbin/enhance-db-backup
FILES_INSTALL_BIN=/usr/local/sbin/enhance-files-backup
CONFIG_DIR=/etc/enhance-db-backup
ENV_FILE="$CONFIG_DIR/env"
RCLONE_CONFIG_FILE="$CONFIG_DIR/rclone.conf"
DB_SERVICE_FILE=/etc/systemd/system/enhance-db-backup.service
DB_TIMER_FILE=/etc/systemd/system/enhance-db-backup.timer
FILES_SERVICE_FILE=/etc/systemd/system/enhance-files-backup.service
FILES_TIMER_FILE=/etc/systemd/system/enhance-files-backup.timer

# Where the runners are fetched from when install.sh is piped straight from
# GitHub (curl one-liner) instead of run inside a clone. Override to install
# from a fork or branch.
REPO_RAW_BASE=${REPO_RAW_BASE:-https://raw.githubusercontent.com/wnstify/backup-enhance/main}

log() {
  printf '[install] %s\n' "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

shell_quote() {
  printf '%q' "$1"
}

normalize_path() {
  local path=$1
  path=${path#/}
  path=${path%/}
  printf '%s' "$path"
}

# database-backups/... targets get a parallel file-backups/... target; anything
# else gets a /files subfolder so both jobs never share a prefix.
derive_files_target() {
  local db_target=$1
  if [[ "$db_target" == *database-backups* ]]; then
    printf '%s' "${db_target/database-backups/file-backups}"
  else
    printf '%s/files' "${db_target%/}"
  fi
}

# Map a preset number to a systemd OnCalendar value; pass anything else through
# so operators can paste a custom schedule.
resolve_db_timer() {
  case "$1" in
    1) printf '%s' '*-*-* *:00:00' ;;
    2) printf '%s' '*-*-* 00/2:00:00' ;;
    3) printf '%s' '*-*-* 00/3:00:00' ;;
    4) printf '%s' '*-*-* 00/6:00:00' ;;
    5) printf '%s' '*-*-* 02,14:30:00' ;;
    6) printf '%s' '*-*-* 02:30:00' ;;
    *) printf '%s' "$1" ;;
  esac
}

resolve_files_timer() {
  case "$1" in
    1) printf '%s' '*-*-* 03:00:00' ;;
    2) printf '%s' '*-*-01/3 04:00:00' ;;
    3) printf '%s' 'Sun *-*-* 04:00:00' ;;
    4) printf '%s' '*-*-01/10 04:00:00' ;;
    5) printf '%s' '*-*-01/14 04:00:00' ;;
    6) printf '%s' '*-*-01 04:00:00' ;;
    *) printf '%s' "$1" ;;
  esac
}

env_line() {
  printf '%s=%s\n' "$1" "$(shell_quote "$2")"
}

runner_url() {
  printf '%s/%s' "${REPO_RAW_BASE%/}" "$1"
}

# Render the full env consumed by both runners. Reads the *_VALUE answers set by
# gather(); every key either runner needs must appear here or that job silently
# falls back to a default (or breaks).
render_env() {
  env_line BACKUP_RCLONE_CONFIG "$RCLONE_CONFIG_FILE"
  env_line BACKUP_RCLONE_TARGET "$BACKUP_RCLONE_TARGET_VALUE"
  env_line BACKUP_WEB_ROOT "$BACKUP_WEB_ROOT_VALUE"
  env_line BACKUP_TMP_PARENT "$BACKUP_TMP_PARENT_VALUE"
  env_line BACKUP_DATE_FORMAT "$BACKUP_DATE_FORMAT_VALUE"
  env_line BACKUP_NAME_MODE "$BACKUP_NAME_MODE_VALUE"
  env_line BACKUP_MYSQL_USER "root"
  env_line BACKUP_MYSQL_SOCKET "/run/mysqld/mysqld.sock"
  env_line BACKUP_LOCK_MODE "auto"
  env_line BACKUP_UPLOAD_RETRIES "3"
  env_line BACKUP_UPLOAD_RETRY_DELAY "30"
  env_line BACKUP_RCLONE_LOW_LEVEL_RETRIES "3"
  env_line BACKUP_VERIFY_MODE "size"
  env_line BACKUP_RETENTION_DAYS "$BACKUP_RETENTION_DAYS_VALUE"
  env_line FILES_BACKUP_RCLONE_TARGET "$FILES_TARGET_VALUE"
  env_line FILES_BACKUP_RETENTION_DAYS "$FILES_RETENTION_VALUE"
  env_line FILES_BACKUP_VERIFY_MODE "$FILES_VERIFY_VALUE"
  env_line FILES_BACKUP_ARCHIVE_LAYOUT "$FILES_LAYOUT_VALUE"
  env_line FILES_BACKUP_TMP_PARENT "/var/tmp/enhance-files-backup"
}

# hard_delete = true so retention permanently removes B2 object versions
# instead of only hiding them. See enhance-db-backup.sh prune_remote.
render_rclone_conf() {
  local account=$1 key=$2
  cat <<RCLONE
[b2]
type = b2
account = $account
key = $key
hard_delete = true
RCLONE
}

render_service() {
  local description=$1 exec_path=$2
  cat <<SERVICE
[Unit]
Description=$description
Wants=network-online.target
After=network-online.target mariadb.service

[Service]
Type=oneshot
ExecStart=$exec_path
TimeoutStartSec=0
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
SERVICE
}

render_timer() {
  local description=$1 oncalendar=$2 randomized_delay=$3
  cat <<TIMER
[Unit]
Description=$description

[Timer]
OnCalendar=$oncalendar
Persistent=true
RandomizedDelaySec=$randomized_delay

[Install]
WantedBy=timers.target
TIMER
}

# Inline the shared library into a runner, emitting a standalone script on
# stdout: the single `source ...enhance-backup-lib.sh` line is replaced by the
# library body (its shebang stripped). Defined above the source-guard so
# test_assemble.sh can drive it without running the installer.
assemble_runner() {
  local runner=$1 lib=$2
  LIB_BODY=$(tail -n +2 "$lib") awk '
    /source.*enhance-backup-lib\.sh/ { print ENVIRON["LIB_BODY"]; next }
    { print }
  ' "$runner"
}

# Tests source this file for the pure renderers above; stop before the
# interactive install runs. Sourced iff BASH_SOURCE is set and differs from $0;
# when piped (`curl | bash`) or run as `bash -c`, BASH_SOURCE is unset and the
# install must proceed rather than `return` from a non-sourced script.
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return 0
fi

# --------------------------------------------------------------------------
# Interactive install below. Nothing here runs when the file is sourced.
# --------------------------------------------------------------------------

if ((EUID != 0)); then
  exec sudo -- "$0" "$@"
fi

prompt() {
  local var_name=$1
  local label=$2
  local default=${3:-}
  local value

  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value
    value=${value:-$default}
  else
    read -r -p "$label: " value
  fi
  printf -v "$var_name" '%s' "$value"
}

prompt_secret() {
  local var_name=$1
  local label=$2
  local value
  read -r -s -p "$label: " value
  printf '\n'
  printf -v "$var_name" '%s' "$value"
}

yes_no() {
  local var_name=$1
  local label=$2
  local default=${3:-y}
  local value
  read -r -p "$label [$default]: " value
  value=${value:-$default}
  case "$value" in
    y|Y|yes|YES) printf -v "$var_name" 'yes' ;;
    *) printf -v "$var_name" 'no' ;;
  esac
}

prompt_db_timer() {
  local var_name=$1 default=$2 value
  cat <<'TIMER_OPTIONS'
Database timer presets:
  1) Hourly:              *-*-* *:00:00
  2) Every 2 hours:       *-*-* 00/2:00:00
  3) Every 3 hours:       *-*-* 00/3:00:00
  4) Every 6 hours:       *-*-* 00/6:00:00
  5) Twice daily:         *-*-* 02,14:30:00
  6) Daily default:       *-*-* 02:30:00
Enter a preset number, or paste a custom systemd OnCalendar value.
TIMER_OPTIONS
  read -r -p "Database OnCalendar schedule [$default]: " value
  value=${value:-$default}
  printf -v "$var_name" '%s' "$(resolve_db_timer "$value")"
}

prompt_files_timer() {
  local var_name=$1 default=$2 value
  cat <<'TIMER_OPTIONS'
Files timer presets:
  1) Daily:               *-*-* 03:00:00
  2) Every 3 days:        *-*-01/3 04:00:00
  3) Weekly:              Sun *-*-* 04:00:00
  4) Every 10 days:       *-*-01/10 04:00:00
  5) Every 14 days:       *-*-01/14 04:00:00
  6) Monthly:             *-*-01 04:00:00
Enter a preset number, or paste a custom systemd OnCalendar value.
TIMER_OPTIONS
  read -r -p "Files OnCalendar schedule [$default]: " value
  value=${value:-$default}
  printf -v "$var_name" '%s' "$(resolve_files_timer "$value")"
}

# When piped from GitHub the runners are not on disk next to this script, so
# fetch them into a temp dir from REPO_RAW_BASE.
if [[ ! -f "$DB_RUNNER_SOURCE" || ! -f "$FILES_RUNNER_SOURCE" || ! -f "$LIB_RUNNER_SOURCE" ]]; then
  command -v curl >/dev/null 2>&1 || { apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y curl; }
  BOOTSTRAP_DIR=$(mktemp -d)
  trap 'rm -rf "$BOOTSTRAP_DIR"' EXIT
  log "Fetching runners and library from $REPO_RAW_BASE"
  for runner in enhance-db-backup.sh enhance-files-backup.sh enhance-backup-lib.sh; do
    curl -fsSL "$(runner_url "$runner")" -o "$BOOTSTRAP_DIR/$runner" \
      || die "Failed to download $runner from $REPO_RAW_BASE"
    [[ -s "$BOOTSTRAP_DIR/$runner" ]] || die "Downloaded $runner is empty"
  done
  DB_RUNNER_SOURCE="$BOOTSTRAP_DIR/enhance-db-backup.sh"
  FILES_RUNNER_SOURCE="$BOOTSTRAP_DIR/enhance-files-backup.sh"
  LIB_RUNNER_SOURCE="$BOOTSTRAP_DIR/enhance-backup-lib.sh"
fi

[[ -f "$DB_RUNNER_SOURCE" ]] || die "Runner not found: $DB_RUNNER_SOURCE"
[[ -f "$FILES_RUNNER_SOURCE" ]] || die "Runner not found: $FILES_RUNNER_SOURCE"
[[ -f "$LIB_RUNNER_SOURCE" ]] || die "Library not found: $LIB_RUNNER_SOURCE"

# Assemble a runner into a standalone fat file, validate it, then install it.
# Guards against ever shipping a runner that fails to parse or still points at
# a library file that won't exist in /usr/local/sbin.
install_runner() {
  local src=$1 dest=$2 tmp
  tmp=$(mktemp)
  assemble_runner "$src" "$LIB_RUNNER_SOURCE" >"$tmp"
  bash -n "$tmp" || die "Assembled runner failed syntax check: $dest"
  ! grep -qE 'source.*enhance-backup-lib' "$tmp" \
    || die "Assembled runner still sources the library: $dest"
  install -o root -g root -m 0755 "$tmp" "$dest"
  rm -f "$tmp"
}

default_host=$(hostname -s 2>/dev/null || hostname)

# Prefill defaults from an existing install so re-running upgrades in place.
existing_bucket=""
if [[ -r "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  if [[ "${BACKUP_RCLONE_TARGET:-}" =~ ^b2:([^/]+)/ ]]; then
    existing_bucket="${BASH_REMATCH[1]}"
  fi
fi

echo
log "Backblaze B2 rclone settings"
REUSE_RCLONE=no
if [[ -s "$RCLONE_CONFIG_FILE" ]]; then
  yes_no REUSE_RCLONE "Existing B2 config found at $RCLONE_CONFIG_FILE. Keep the stored key?" "y"
fi
if [[ "$REUSE_RCLONE" == "no" ]]; then
  prompt B2_KEY_ID "Backblaze application key ID"
  prompt_secret B2_APP_KEY "Backblaze application key"
fi
prompt B2_BUCKET "Backblaze bucket name" "$existing_bucket"

default_remote_path="database-backups/$default_host"
if [[ "${BACKUP_RCLONE_TARGET:-}" =~ ^b2:[^/]+/(.+)$ ]]; then
  default_remote_path="${BASH_REMATCH[1]}"
fi
prompt BACKUP_REMOTE_PATH "Database backup folder inside bucket" "$default_remote_path"

echo
log "Local backup discovery settings"
prompt BACKUP_WEB_ROOT_VALUE "Website root" "${BACKUP_WEB_ROOT:-/var/www}"
prompt BACKUP_TMP_PARENT_VALUE "Temporary working directory" "${BACKUP_TMP_PARENT:-/var/tmp/enhance-db-backup}"
prompt BACKUP_DATE_FORMAT_VALUE "Archive date format" "${BACKUP_DATE_FORMAT:-%-d-%-m-%y_%H-%M}"
prompt BACKUP_NAME_MODE_VALUE "Archive name mode: first-label or full-domain" "${BACKUP_NAME_MODE:-first-label}"
prompt BACKUP_RETENTION_DAYS_VALUE "Delete remote database archives older than N days, 0 disables" "${BACKUP_RETENTION_DAYS:-30}"

BACKUP_RCLONE_TARGET_VALUE="b2:${B2_BUCKET}/$(normalize_path "$BACKUP_REMOTE_PATH")"

echo
log "File backup settings"
prompt FILES_TARGET_VALUE "File backup rclone target" "${FILES_BACKUP_RCLONE_TARGET:-$(derive_files_target "$BACKUP_RCLONE_TARGET_VALUE")}"
prompt FILES_RETENTION_VALUE "Delete remote file archives older than N days, 0 disables" "${FILES_BACKUP_RETENTION_DAYS:-30}"
prompt FILES_VERIFY_VALUE "Files verify mode: size or deep" "${FILES_BACKUP_VERIFY_MODE:-size}"
prompt FILES_LAYOUT_VALUE "Files archive layout: contents or public_html" "${FILES_BACKUP_ARCHIVE_LAYOUT:-contents}"

log "Installing packages"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates mariadb-client rclone

install_runner "$DB_RUNNER_SOURCE" "$DB_INSTALL_BIN"
install_runner "$FILES_RUNNER_SOURCE" "$FILES_INSTALL_BIN"
install -o root -g root -m 0700 -d "$CONFIG_DIR"

if [[ -f "$ENV_FILE" ]]; then
  cp -a "$ENV_FILE" "$ENV_FILE.bak.$(date '+%Y%m%d%H%M%S')"
fi

if [[ "$REUSE_RCLONE" == "no" ]]; then
  if [[ -f "$RCLONE_CONFIG_FILE" ]]; then
    cp -a "$RCLONE_CONFIG_FILE" "$RCLONE_CONFIG_FILE.bak.$(date '+%Y%m%d%H%M%S')"
  fi
  umask 077
  render_rclone_conf "$B2_KEY_ID" "$B2_APP_KEY" >"$RCLONE_CONFIG_FILE"
  chmod 600 "$RCLONE_CONFIG_FILE"
  chown root:root "$RCLONE_CONFIG_FILE"
fi
[[ -s "$RCLONE_CONFIG_FILE" ]] || die "Rclone config is missing: $RCLONE_CONFIG_FILE"

render_env >"$ENV_FILE"
chmod 600 "$ENV_FILE"
chown root:root "$ENV_FILE"

log "Testing MariaDB socket access"
mariadb --user=root --socket=/run/mysqld/mysqld.sock --batch --skip-column-names -e 'SELECT VERSION();' >/dev/null

log "Testing rclone access"
rclone --config "$RCLONE_CONFIG_FILE" lsd "b2:${B2_BUCKET}" >/dev/null

render_service "Enhance MariaDB website database backup" "$DB_INSTALL_BIN" >"$DB_SERVICE_FILE"
chmod 0644 "$DB_SERVICE_FILE"
render_service "Enhance WordPress files backup" "$FILES_INSTALL_BIN" >"$FILES_SERVICE_FILE"
chmod 0644 "$FILES_SERVICE_FILE"

yes_no INSTALL_DB_TIMER "Install and enable the database backup timer?" "y"
if [[ "$INSTALL_DB_TIMER" == "yes" ]]; then
  prompt_db_timer DB_TIMER_CALENDAR "*-*-* 02:30:00"
  render_timer "Run Enhance MariaDB website database backup" "$DB_TIMER_CALENDAR" "15m" >"$DB_TIMER_FILE"
  chmod 0644 "$DB_TIMER_FILE"
fi

yes_no INSTALL_FILES_TIMER "Install and enable the files backup timer?" "y"
if [[ "$INSTALL_FILES_TIMER" == "yes" ]]; then
  prompt_files_timer FILES_TIMER_CALENDAR "*-*-* 03:00:00"
  render_timer "Run Enhance WordPress files backup" "$FILES_TIMER_CALENDAR" "20m" >"$FILES_TIMER_FILE"
  chmod 0644 "$FILES_TIMER_FILE"
fi

systemctl daemon-reload
if [[ "$INSTALL_DB_TIMER" == "yes" ]]; then
  systemctl enable --now enhance-db-backup.timer
  log "Database timer enabled: $DB_TIMER_CALENDAR"
fi
if [[ "$INSTALL_FILES_TIMER" == "yes" ]]; then
  systemctl enable --now enhance-files-backup.timer
  log "Files timer enabled: $FILES_TIMER_CALENDAR"
fi

yes_no RUN_DRY "Run a discovery dry-run now?" "y"
if [[ "$RUN_DRY" == "yes" ]]; then
  "$DB_INSTALL_BIN" --dry-run
  "$FILES_INSTALL_BIN" --dry-run
fi

yes_no RUN_NOW "Run the first real backups now?" "n"
if [[ "$RUN_NOW" == "yes" ]]; then
  "$DB_INSTALL_BIN"
  "$FILES_INSTALL_BIN"
fi

log "Installed $DB_INSTALL_BIN and $FILES_INSTALL_BIN"
log "Config stored in $ENV_FILE with mode 600"
log "Rclone config stored in $RCLONE_CONFIG_FILE with mode 600"
log "Use: systemctl status enhance-db-backup.timer enhance-files-backup.timer"
