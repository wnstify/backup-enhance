#!/usr/bin/env bash
set -Eeuo pipefail

if ((EUID != 0)); then
  exec sudo -- "$0" "$@"
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RUNNER_SOURCE="$SCRIPT_DIR/enhance-db-backup.sh"
INSTALL_BIN=/usr/local/sbin/enhance-db-backup
CONFIG_DIR=/etc/enhance-db-backup
ENV_FILE="$CONFIG_DIR/env"
RCLONE_CONFIG_FILE="$CONFIG_DIR/rclone.conf"
SERVICE_FILE=/etc/systemd/system/enhance-db-backup.service
TIMER_FILE=/etc/systemd/system/enhance-db-backup.timer

log() {
  printf '[install] %s\n' "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

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

prompt_db_timer_calendar() {
  local var_name=$1
  local default=$2
  local value

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

  read -r -p "Systemd OnCalendar schedule [$default]: " value
  value=${value:-$default}
  case "$value" in
    1) value='*-*-* *:00:00' ;;
    2) value='*-*-* 00/2:00:00' ;;
    3) value='*-*-* 00/3:00:00' ;;
    4) value='*-*-* 00/6:00:00' ;;
    5) value='*-*-* 02,14:30:00' ;;
    6) value='*-*-* 02:30:00' ;;
  esac
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
    y|Y|yes|YES)
      printf -v "$var_name" 'yes'
      ;;
    *)
      printf -v "$var_name" 'no'
      ;;
  esac
}

shell_quote() {
  printf '%q' "$1"
}

write_env_line() {
  local key=$1
  local value=$2
  printf '%s=%s\n' "$key" "$(shell_quote "$value")" >>"$ENV_FILE"
}

normalize_path() {
  local path=$1
  path=${path#/}
  path=${path%/}
  printf '%s' "$path"
}

[[ -f "$RUNNER_SOURCE" ]] || die "Runner not found: $RUNNER_SOURCE"

log "Installing packages"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates mariadb-client rclone

default_host=$(hostname -s 2>/dev/null || hostname)

echo
log "Backblaze B2 rclone settings"
prompt B2_KEY_ID "Backblaze application key ID"
prompt_secret B2_APP_KEY "Backblaze application key"
prompt B2_BUCKET "Backblaze bucket name"
prompt BACKUP_REMOTE_PATH "Backup folder inside bucket" "database-backups/$default_host"

echo
log "Local backup discovery settings"
prompt BACKUP_WEB_ROOT_VALUE "Website root" "/var/www"
prompt BACKUP_TMP_PARENT_VALUE "Temporary working directory" "/var/tmp/enhance-db-backup"
prompt BACKUP_DATE_FORMAT_VALUE "Archive date format" "%-d-%-m-%y_%H-%M"
prompt BACKUP_NAME_MODE_VALUE "Archive name mode: first-label or full-domain" "first-label"
prompt BACKUP_RETENTION_DAYS_VALUE "Delete remote archives older than N days, 0 disables" "30"

BACKUP_REMOTE_PATH=$(normalize_path "$BACKUP_REMOTE_PATH")
BACKUP_RCLONE_TARGET_VALUE="b2:${B2_BUCKET}/${BACKUP_REMOTE_PATH}"

install -o root -g root -m 0755 "$RUNNER_SOURCE" "$INSTALL_BIN"
install -o root -g root -m 0700 -d "$CONFIG_DIR"

if [[ -f "$ENV_FILE" ]]; then
  cp -a "$ENV_FILE" "$ENV_FILE.bak.$(date '+%Y%m%d%H%M%S')"
fi
if [[ -f "$RCLONE_CONFIG_FILE" ]]; then
  cp -a "$RCLONE_CONFIG_FILE" "$RCLONE_CONFIG_FILE.bak.$(date '+%Y%m%d%H%M%S')"
fi

umask 077
cat >"$RCLONE_CONFIG_FILE" <<RCLONE
[b2]
type = b2
account = $B2_KEY_ID
key = $B2_APP_KEY
hard_delete = true
RCLONE
chmod 600 "$RCLONE_CONFIG_FILE"
chown root:root "$RCLONE_CONFIG_FILE"

: >"$ENV_FILE"
write_env_line BACKUP_RCLONE_CONFIG "$RCLONE_CONFIG_FILE"
write_env_line BACKUP_RCLONE_TARGET "$BACKUP_RCLONE_TARGET_VALUE"
write_env_line BACKUP_WEB_ROOT "$BACKUP_WEB_ROOT_VALUE"
write_env_line BACKUP_TMP_PARENT "$BACKUP_TMP_PARENT_VALUE"
write_env_line BACKUP_DATE_FORMAT "$BACKUP_DATE_FORMAT_VALUE"
write_env_line BACKUP_NAME_MODE "$BACKUP_NAME_MODE_VALUE"
write_env_line BACKUP_MYSQL_USER "root"
write_env_line BACKUP_MYSQL_SOCKET "/run/mysqld/mysqld.sock"
write_env_line BACKUP_LOCK_MODE "auto"
write_env_line BACKUP_UPLOAD_RETRIES "3"
write_env_line BACKUP_UPLOAD_RETRY_DELAY "30"
write_env_line BACKUP_RCLONE_LOW_LEVEL_RETRIES "3"
write_env_line BACKUP_VERIFY_MODE "size"
write_env_line BACKUP_RETENTION_DAYS "$BACKUP_RETENTION_DAYS_VALUE"
chmod 600 "$ENV_FILE"
chown root:root "$ENV_FILE"

log "Testing MariaDB socket access"
mariadb --user=root --socket=/run/mysqld/mysqld.sock --batch --skip-column-names -e 'SELECT VERSION();' >/dev/null

log "Testing rclone access"
rclone --config "$RCLONE_CONFIG_FILE" lsd "b2:${B2_BUCKET}" >/dev/null

cat >"$SERVICE_FILE" <<SERVICE
[Unit]
Description=Enhance MariaDB website database backup
Wants=network-online.target
After=network-online.target mariadb.service

[Service]
Type=oneshot
ExecStart=$INSTALL_BIN
TimeoutStartSec=0
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
SERVICE

chmod 0644 "$SERVICE_FILE"

yes_no INSTALL_TIMER "Install and enable a systemd timer?" "y"
if [[ "$INSTALL_TIMER" == "yes" ]]; then
  prompt_db_timer_calendar TIMER_CALENDAR "*-*-* 02:30:00"
  cat >"$TIMER_FILE" <<TIMER
[Unit]
Description=Run Enhance MariaDB website database backup

[Timer]
OnCalendar=$TIMER_CALENDAR
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
TIMER
  chmod 0644 "$TIMER_FILE"
  systemctl daemon-reload
  systemctl enable --now enhance-db-backup.timer
  log "Timer enabled: $TIMER_CALENDAR"
else
  systemctl daemon-reload
fi

yes_no RUN_DRY "Run a discovery dry-run now?" "y"
if [[ "$RUN_DRY" == "yes" ]]; then
  "$INSTALL_BIN" --dry-run
fi

yes_no RUN_NOW "Run the first real backup now?" "n"
if [[ "$RUN_NOW" == "yes" ]]; then
  "$INSTALL_BIN"
fi

log "Installed $INSTALL_BIN"
log "Config stored in $ENV_FILE with mode 600"
log "Rclone config stored in $RCLONE_CONFIG_FILE with mode 600"
log "Use: systemctl status enhance-db-backup.timer"
