#!/usr/bin/env bash
# Behavior tests for the unified installer's pure renderers. Sources install.sh
# behind its source-guard (no apt, no sudo, no writes) and drives the functions
# that turn answers into config. These are the paths where a silent mistake
# breaks a backup: a missing env key, a wrong OnCalendar, a bad files target.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1090
source "$SCRIPT_DIR/install.sh"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); }

# --- Behavior 1: files target is derived from the database target ------------
[[ "$(derive_files_target 'b2:bucket/database-backups/host')" == 'b2:bucket/file-backups/host' ]] \
  || fail "derive_files_target: database-backups should map to file-backups"; ok
[[ "$(derive_files_target 'b2:bucket/custom/path')" == 'b2:bucket/custom/path/files' ]] \
  || fail "derive_files_target: non-standard path should fall back to /files suffix"; ok

# --- Behavior 2: timer presets resolve to the right OnCalendar ---------------
[[ "$(resolve_db_timer 6)" == '*-*-* 02:30:00' ]]     || fail "resolve_db_timer 6"; ok
[[ "$(resolve_db_timer 1)" == '*-*-* *:00:00' ]]      || fail "resolve_db_timer 1"; ok
[[ "$(resolve_files_timer 3)" == 'Sun *-*-* 04:00:00' ]] || fail "resolve_files_timer 3"; ok
[[ "$(resolve_files_timer 6)" == '*-*-01 04:00:00' ]] || fail "resolve_files_timer 6"; ok
# custom value passes through untouched
[[ "$(resolve_db_timer '*-*-* 05:15:00')" == '*-*-* 05:15:00' ]] || fail "resolve_db_timer passthrough"; ok

# --- Behavior 3: env file carries every key both runners need ----------------
BACKUP_RCLONE_TARGET_VALUE='b2:bucket/database-backups/host'
BACKUP_WEB_ROOT_VALUE='/var/www'
BACKUP_TMP_PARENT_VALUE='/var/tmp/enhance-db-backup'
BACKUP_DATE_FORMAT_VALUE='%-d-%-m-%y_%H-%M'
BACKUP_NAME_MODE_VALUE='first-label'
BACKUP_RETENTION_DAYS_VALUE='30'
FILES_TARGET_VALUE='b2:bucket/file-backups/host'
FILES_RETENTION_VALUE='30'
FILES_VERIFY_VALUE='size'
FILES_LAYOUT_VALUE='contents'
env_out=$(render_env)

for key in \
  BACKUP_RCLONE_CONFIG BACKUP_RCLONE_TARGET BACKUP_WEB_ROOT BACKUP_TMP_PARENT \
  BACKUP_DATE_FORMAT BACKUP_NAME_MODE BACKUP_MYSQL_USER BACKUP_MYSQL_SOCKET \
  BACKUP_LOCK_MODE BACKUP_UPLOAD_RETRIES BACKUP_UPLOAD_RETRY_DELAY \
  BACKUP_RCLONE_LOW_LEVEL_RETRIES BACKUP_VERIFY_MODE BACKUP_RETENTION_DAYS \
  FILES_BACKUP_RCLONE_TARGET FILES_BACKUP_RETENTION_DAYS FILES_BACKUP_VERIFY_MODE \
  FILES_BACKUP_ARCHIVE_LAYOUT FILES_BACKUP_TMP_PARENT; do
  grep -qE "^${key}=" <<<"$env_out" || fail "render_env: missing key ${key}"; ok
done
# the derived targets actually land in the env, not just the key names
grep -qF "FILES_BACKUP_RCLONE_TARGET=b2:bucket/file-backups/host" <<<"$env_out" \
  || fail "render_env: files target value not written"; ok
# values are shell-quoted so a date format with % survives sourcing
grep -q "BACKUP_DATE_FORMAT=" <<<"$env_out" || fail "render_env: date format not written"; ok

# --- Behavior 4: service/timer units render with the hardening --------------
svc=$(render_service "Test service" "/usr/local/sbin/enhance-db-backup")
grep -qF 'ExecStart=/usr/local/sbin/enhance-db-backup' <<<"$svc" || fail "render_service: ExecStart"; ok
grep -qF 'TimeoutStartSec=0' <<<"$svc" || fail "render_service: missing TimeoutStartSec hardening"; ok
grep -qF 'Type=oneshot' <<<"$svc" || fail "render_service: Type"; ok

tmr=$(render_timer "Test timer" '*-*-* 02:30:00' '15m')
grep -qF 'OnCalendar=*-*-* 02:30:00' <<<"$tmr" || fail "render_timer: OnCalendar"; ok
grep -qF 'Persistent=true' <<<"$tmr" || fail "render_timer: Persistent"; ok
grep -qF 'RandomizedDelaySec=15m' <<<"$tmr" || fail "render_timer: RandomizedDelaySec"; ok

# --- Bonus: rclone.conf carries hard_delete (guards the B2 versioning fix) ---
grep -qF 'hard_delete = true' <<<"$(render_rclone_conf keyid appkey)" \
  || fail "render_rclone_conf: hard_delete missing (soft-delete would leak B2 versions)"; ok

echo "PASS: $pass checks"
