#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE=${ENV_FILE:-/etc/enhance-db-backup/env}
DRY_RUN=false
RUN_PRUNE=true
ORIGINAL_ARGS=("$@")

# Shared backup functions live next to the runner in a clone; the installer
# inlines this file so the installed runner stays a single standalone script.
source "$(dirname "${BASH_SOURCE[0]}")/enhance-backup-lib.sh" || { echo "cannot load enhance-backup-lib.sh" >&2; exit 1; }

# Paths (relative to the archive root) to drop from every file backup: junk
# archives and the working dirs of other WordPress backup plugins. Applied with
# the layout's prefix by build_tar_excludes so both layouts exclude the same set.
tar_exclude_paths=(
  '*.zip' '*.ZIP' '*.wpress' '*.WPRESS' '*.tar' '*.tar.gz' '*.tgz'
  '*.sql' '*.sql.gz' '*.7z' '*.rar'
  'wp-content/cache'
  'wp-content/litespeed'
  'wp-content/ai1wm-backups'
  'wp-content/updraft'
  'wp-content/backups'
  'wp-content/backups-dup-*'
  'wp-content/backup-db'
  'wp-content/backup-guard'
  'wp-content/backupbuddy_backups'
  'wp-content/backupbuddy_temp'
  'wp-content/backuply'
  'wp-content/backupwordpress*'
  'wp-content/wpvividbackups'
  'wp-snapshots'
  'wp-content/uploads/ai1wm-backups'
  'wp-content/uploads/backwpup*'
  'wp-content/uploads/backup*'
  'wp-content/uploads/backups-dup-*'
  'wp-content/uploads/backupbuddy_backups'
  'wp-content/uploads/backupbuddy_temp'
  'wp-content/uploads/duplicator'
  'wp-content/uploads/ithemes-security/backups'
  'wp-content/uploads/pb_backupbuddy'
  'wp-content/uploads/snapshots'
  'wp-content/uploads/tCapsule'
  'wp-content/uploads/updraft'
  'wp-content/uploads/wp-clone'
  'wp-content/uploads/wp-migrate-db'
  'wp-content/uploads/wp-staging'
  'wp-content/uploads/wpvividbackups'
)

# Junk-archive globs matched anywhere in the tree, regardless of layout prefix.
tar_exclude_global=(
  '*.zip' '*.ZIP' '*.wpress' '*.WPRESS' '*.tar' '*.tar.gz' '*.tgz'
  '*.sql' '*.sql.gz' '*.7z' '*.rar'
)

# Populate tar_excludes for a layout whose archive root sits at $prefix
# (e.g. 'public_html/' or './'). One list, two layouts, no drift.
build_tar_excludes() {
  local prefix=$1 p
  tar_excludes=(--exclude='*.[wW][pP][rR][eE][sS][sS]')
  for p in "${tar_exclude_paths[@]}"; do
    tar_excludes+=(--exclude="${prefix}${p}")
  done
  for p in "${tar_exclude_global[@]}"; do
    tar_excludes+=(--exclude="$p")
  done
}

# Read the site's home/siteurl from wp_options to name the archive. Connects
# through the configured MYSQL array (same socket/user as the db runner) so both
# jobs resolve the same URL and derive the same slug for a site.
mysql_site_url() {
  local db=$1
  local table_prefix=$2
  local dbq tableq

  command -v mariadb >/dev/null 2>&1 || return 0
  [[ -n "$db" ]] || return 0

  dbq=$(quote_identifier "$db")
  tableq=$(quote_identifier "${table_prefix:-wp_}options")
  "${MYSQL[@]}" --execute "SELECT option_value FROM ${dbq}.${tableq} WHERE option_name IN ('home','siteurl') ORDER BY FIELD(option_name,'home','siteurl') LIMIT 1;" 2>/dev/null || true
}

# Allow tests to source this file for its functions without running the backup.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] || return 0

usage() {
  cat <<'USAGE'
Usage: enhance-files-backup [--dry-run] [--no-prune]

Discovers WordPress public_html directories under /var/www, archives necessary
WordPress files with numeric ownership and permissions preserved, uploads plain
tar.gz archives with rclone, verifies the remote object, and removes local
archives only after successful verification.

Options:
  --dry-run    Show discovered sites and archive names without uploading.
  --no-prune   Skip remote retention cleanup for this run.
USAGE
}

while (($#)); do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --no-prune)
      RUN_PRUNE=false
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if ((EUID != 0)); then
  exec sudo -- "$0" "${ORIGINAL_ARGS[@]}"
fi

if [[ ! -r "$ENV_FILE" ]]; then
  die "Config file is missing or unreadable: $ENV_FILE"
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

BACKUP_WEB_ROOT=${BACKUP_WEB_ROOT:-/var/www}
BACKUP_FIND_MAXDEPTH=${BACKUP_FIND_MAXDEPTH:-4}
BACKUP_DATE_FORMAT=${BACKUP_DATE_FORMAT:-%-d-%-m-%y_%H-%M}
BACKUP_NAME_MODE=${BACKUP_NAME_MODE:-first-label}
BACKUP_MYSQL_USER=${BACKUP_MYSQL_USER:-root}
BACKUP_MYSQL_SOCKET=${BACKUP_MYSQL_SOCKET:-/run/mysqld/mysqld.sock}
BACKUP_RCLONE_CONFIG=${BACKUP_RCLONE_CONFIG:-/etc/enhance-db-backup/rclone.conf}
BACKUP_RCLONE_TARGET=${BACKUP_RCLONE_TARGET:-}
FILES_BACKUP_RCLONE_TARGET=${FILES_BACKUP_RCLONE_TARGET:-}
FILES_BACKUP_TMP_PARENT=${FILES_BACKUP_TMP_PARENT:-/var/tmp/enhance-files-backup}
FILES_BACKUP_FAILED_DIR=${FILES_BACKUP_FAILED_DIR:-$FILES_BACKUP_TMP_PARENT/failed}
FILES_BACKUP_RETENTION_DAYS=${FILES_BACKUP_RETENTION_DAYS:-30}
FILES_BACKUP_UPLOAD_RETRIES=${FILES_BACKUP_UPLOAD_RETRIES:-${BACKUP_UPLOAD_RETRIES:-3}}
FILES_BACKUP_UPLOAD_RETRY_DELAY=${FILES_BACKUP_UPLOAD_RETRY_DELAY:-${BACKUP_UPLOAD_RETRY_DELAY:-30}}
FILES_BACKUP_RCLONE_LOW_LEVEL_RETRIES=${FILES_BACKUP_RCLONE_LOW_LEVEL_RETRIES:-${BACKUP_RCLONE_LOW_LEVEL_RETRIES:-3}}
FILES_BACKUP_VERIFY_MODE=${FILES_BACKUP_VERIFY_MODE:-size}
FILES_BACKUP_ARCHIVE_LAYOUT=${FILES_BACKUP_ARCHIVE_LAYOUT:-contents}

if [[ -z "$FILES_BACKUP_RCLONE_TARGET" ]]; then
  if [[ "$BACKUP_RCLONE_TARGET" == *database-backups* ]]; then
    FILES_BACKUP_RCLONE_TARGET=${BACKUP_RCLONE_TARGET/database-backups/file-backups}
  elif [[ -n "$BACKUP_RCLONE_TARGET" ]]; then
    FILES_BACKUP_RCLONE_TARGET="${BACKUP_RCLONE_TARGET%/}/files"
  fi
fi
FILES_BACKUP_RCLONE_TARGET=${FILES_BACKUP_RCLONE_TARGET%/}

require_command basename
require_command date
require_command dirname
require_command find
require_command sed
require_command tar
require_command tr
if [[ "$DRY_RUN" == "false" ]]; then
  require_command grep
  require_command mktemp
  require_command rclone
  require_command stat
fi

[[ -d "$BACKUP_WEB_ROOT" ]] || die "Website root does not exist: $BACKUP_WEB_ROOT"
if [[ "$DRY_RUN" == "false" ]]; then
  [[ -r "$BACKUP_RCLONE_CONFIG" ]] || die "Rclone config is missing or unreadable: $BACKUP_RCLONE_CONFIG"
  [[ -n "$FILES_BACKUP_RCLONE_TARGET" ]] || die "FILES_BACKUP_RCLONE_TARGET could not be derived"
fi

RCLONE=(rclone --config "$BACKUP_RCLONE_CONFIG")
MYSQL=(mariadb --batch --raw --skip-column-names --user="$BACKUP_MYSQL_USER")
if [[ -n "$BACKUP_MYSQL_SOCKET" ]]; then
  MYSQL+=(--socket="$BACKUP_MYSQL_SOCKET")
fi

# Assign the library's generic-global contract from this runner's FILES_BACKUP_* env.
RCLONE_TARGET=$FILES_BACKUP_RCLONE_TARGET
VERIFY_MODE=$FILES_BACKUP_VERIFY_MODE
UPLOAD_RETRIES=$FILES_BACKUP_UPLOAD_RETRIES
UPLOAD_RETRY_DELAY=$FILES_BACKUP_UPLOAD_RETRY_DELAY
LOW_LEVEL_RETRIES=$FILES_BACKUP_RCLONE_LOW_LEVEL_RETRIES
FAILED_DIR=$FILES_BACKUP_FAILED_DIR
RETENTION_DAYS=$FILES_BACKUP_RETENTION_DAYS

RUN_DIR=""
cleanup() {
  if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
    rm -rf -- "$RUN_DIR"
  fi
}
trap cleanup EXIT

backup_site_files() {
  local config_path=$1
  local public_html site_home db table_prefix site_url site_host slug timestamp archive_name archive_file

  public_html=$(dirname "$config_path")
  site_home=$(dirname "$public_html")
  [[ "$(basename "$public_html")" == "public_html" ]] || return 0

  db=$(extract_define DB_NAME "$config_path")
  table_prefix=$(extract_table_prefix "$config_path")
  site_url=$(mysql_site_url "$db" "$table_prefix" | head -n 1)
  site_host=$(site_host_from_url "$site_url")
  if [[ -z "$site_host" ]]; then
    site_host=$(basename "$site_home")
  fi

  slug=$(sanitize_slug "$site_host")
  timestamp=$(date "+$BACKUP_DATE_FORMAT")
  archive_name="${slug}_files_${timestamp}.tar.gz"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "Would back up files site=${site_host} path=${public_html} archive=${archive_name}"
    return 0
  fi

  archive_file="$RUN_DIR/$archive_name"
  log "Creating file archive site=${site_host} path=${public_html} layout=${FILES_BACKUP_ARCHIVE_LAYOUT}"
  case "$FILES_BACKUP_ARCHIVE_LAYOUT" in
    contents)
      build_tar_excludes "./"
      tar \
        --create \
        --gzip \
        --file "$archive_file" \
        --directory "$public_html" \
        --numeric-owner \
        --acls \
        --xattrs \
        --one-file-system \
        --ignore-failed-read \
        --warning=no-file-changed \
        --warning=no-file-removed \
        "${tar_excludes[@]}" \
        .
      ;;
    public_html)
      build_tar_excludes "public_html/"
      tar \
        --create \
        --gzip \
        --file "$archive_file" \
        --directory "$site_home" \
        --numeric-owner \
        --acls \
        --xattrs \
        --one-file-system \
        --ignore-failed-read \
        --warning=no-file-changed \
        --warning=no-file-removed \
        "${tar_excludes[@]}" \
        public_html
      ;;
    *)
      die "Invalid FILES_BACKUP_ARCHIVE_LAYOUT=${FILES_BACKUP_ARCHIVE_LAYOUT}; use contents or public_html"
      ;;
  esac
  chmod 600 "$archive_file"

  if ! upload_archive_with_retries "$archive_file" "$archive_name"; then
    preserve_failed_archive "$archive_file" "$archive_name"
    return 1
  fi

  rm -f -- "$archive_file"
  log "Finished files site=${site_host} archive=${archive_name}"
}

declare -a CONFIGS=()
while IFS= read -r -d '' config_path; do
  CONFIGS+=("$config_path")
done < <(discover_wp_configs)

if ((${#CONFIGS[@]} == 0)); then
  die "No WordPress wp-config.php files found under $BACKUP_WEB_ROOT"
fi

if [[ "$DRY_RUN" == "false" ]]; then
  mkdir -p "$FILES_BACKUP_TMP_PARENT"
  chmod 700 "$FILES_BACKUP_TMP_PARENT"
  RUN_DIR=$(mktemp -d "$FILES_BACKUP_TMP_PARENT/run.XXXXXXXX")
  chmod 700 "$RUN_DIR"
fi

for config_path in "${CONFIGS[@]}"; do
  backup_site_files "$config_path"
done

if [[ "$DRY_RUN" == "false" && "$RUN_PRUNE" == "true" && "${RETENTION_DAYS:-0}" != "0" ]]; then
  prune_remote "$RCLONE_TARGET" "$RETENTION_DAYS"
fi

log "File backup run complete"
