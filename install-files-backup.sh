#!/usr/bin/env bash
set -Eeuo pipefail

if ((EUID != 0)); then
  exec sudo -- "$0" "$@"
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RUNNER_SOURCE="$SCRIPT_DIR/enhance-files-backup.sh"
INSTALL_BIN=/usr/local/sbin/enhance-files-backup
ENV_FILE=/etc/enhance-db-backup/env
SERVICE_FILE=/etc/systemd/system/enhance-files-backup.service
TIMER_FILE=/etc/systemd/system/enhance-files-backup.timer

log() {
  printf '[install-files] %s\n' "$*"
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

prompt_files_timer_calendar() {
  local var_name=$1
  local default=$2
  local value

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

  read -r -p "Systemd OnCalendar schedule [$default]: " value
  value=${value:-$default}
  case "$value" in
    1) value='*-*-* 03:00:00' ;;
    2) value='*-*-01/3 04:00:00' ;;
    3) value='Sun *-*-* 04:00:00' ;;
    4) value='*-*-01/10 04:00:00' ;;
    5) value='*-*-01/14 04:00:00' ;;
    6) value='*-*-01 04:00:00' ;;
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

set_env_value() {
  local key=$1
  local value=$2
  local escaped
  escaped=$(printf '%q' "$value")
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$escaped" >>"$ENV_FILE"
  fi
}

derive_files_target() {
  local db_target=$1
  if [[ "$db_target" == *database-backups* ]]; then
    printf '%s' "${db_target/database-backups/file-backups}"
  else
    printf '%s/files' "${db_target%/}"
  fi
}

[[ -f "$RUNNER_SOURCE" ]] || die "Runner not found: $RUNNER_SOURCE"
[[ -r "$ENV_FILE" ]] || die "Database backup config missing: $ENV_FILE. Install database backups first."

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates mariadb-client rclone

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

default_target=$(derive_files_target "${BACKUP_RCLONE_TARGET:-}")
prompt FILES_TARGET "File backup rclone target" "$default_target"
prompt FILES_RETENTION "Delete remote file archives older than N days, 0 disables" "30"
prompt FILES_VERIFY "Verify mode: size or deep" "size"
prompt FILES_LAYOUT "Archive layout: contents or public_html" "contents"

install -o root -g root -m 0755 "$RUNNER_SOURCE" "$INSTALL_BIN"
cp -a "$ENV_FILE" "$ENV_FILE.bak.files.$(date '+%Y%m%d%H%M%S')"
set_env_value FILES_BACKUP_RCLONE_TARGET "$FILES_TARGET"
set_env_value FILES_BACKUP_RETENTION_DAYS "$FILES_RETENTION"
set_env_value FILES_BACKUP_VERIFY_MODE "$FILES_VERIFY"
set_env_value FILES_BACKUP_ARCHIVE_LAYOUT "$FILES_LAYOUT"
set_env_value FILES_BACKUP_TMP_PARENT "/var/tmp/enhance-files-backup"
chmod 600 "$ENV_FILE"
chown root:root "$ENV_FILE"

cat >"$SERVICE_FILE" <<SERVICE
[Unit]
Description=Enhance WordPress files backup
Wants=network-online.target
After=network-online.target

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
  prompt_files_timer_calendar TIMER_CALENDAR "*-*-* 03:00:00"
  cat >"$TIMER_FILE" <<TIMER
[Unit]
Description=Run Enhance WordPress files backup

[Timer]
OnCalendar=$TIMER_CALENDAR
Persistent=true
RandomizedDelaySec=20m

[Install]
WantedBy=timers.target
TIMER
  chmod 0644 "$TIMER_FILE"
  systemctl daemon-reload
  systemctl enable --now enhance-files-backup.timer
  log "Timer enabled: $TIMER_CALENDAR"
else
  systemctl daemon-reload
fi

yes_no RUN_DRY "Run a discovery dry-run now?" "y"
if [[ "$RUN_DRY" == "yes" ]]; then
  "$INSTALL_BIN" --dry-run
fi

yes_no RUN_NOW "Run the first real file backup now?" "n"
if [[ "$RUN_NOW" == "yes" ]]; then
  "$INSTALL_BIN"
fi

log "Installed $INSTALL_BIN"
