#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE=${ENV_FILE:-/etc/enhance-db-backup/env}
DRY_RUN=false
RUN_PRUNE=true
ORIGINAL_ARGS=("$@")

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"
}

# Permanently delete remote archives older than the retention window.
# --b2-hard-delete removes the B2 object version instead of only hiding it;
# without it, versioned buckets keep (and bill for) every "deleted" archive.
prune_remote() {
  local target=$1 retention_days=$2
  log "Deleting remote file archives older than ${retention_days}d from ${target}"
  "${RCLONE[@]}" delete "$target" --b2-hard-delete --include '*.tar.gz' --min-age "${retention_days}d"
}

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

die() {
  log "ERROR: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

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

RUN_DIR=""
cleanup() {
  if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
    rm -rf -- "$RUN_DIR"
  fi
}
trap cleanup EXIT

quote_identifier() {
  local value=${1//\`/\`\`}
  printf '`%s`' "$value"
}

extract_define() {
  local name=$1
  local file=$2
  sed -nE "s/^[[:space:]]*define\\([[:space:]]*['\"]${name}['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]+)['\"].*/\\1/p" "$file" | head -n 1
}

extract_table_prefix() {
  local file=$1
  sed -nE "s/^[[:space:]]*\\\$table_prefix[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"].*/\\1/p" "$file" | head -n 1
}

sanitize_slug() {
  local value=$1
  value=${value#www.}
  if [[ "$BACKUP_NAME_MODE" == "first-label" ]]; then
    value=${value%%.*}
  fi
  value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/_/g; s/^[._-]+//; s/[._-]+$//; s/[_]+/_/g')
  if [[ -z "$value" ]]; then
    value=site
  fi
  printf '%s' "$value"
}

mysql_site_url() {
  local db=$1
  local table_prefix=$2
  local dbq tableq

  command -v mariadb >/dev/null 2>&1 || return 0
  [[ -n "$db" ]] || return 0

  dbq=$(quote_identifier "$db")
  tableq=$(quote_identifier "${table_prefix:-wp_}options")
  sudo mariadb --batch --raw --skip-column-names --execute "SELECT option_value FROM ${dbq}.${tableq} WHERE option_name IN ('home','siteurl') ORDER BY FIELD(option_name,'home','siteurl') LIMIT 1;" 2>/dev/null || true
}

site_host_from_url() {
  local url=$1
  url=${url#http://}
  url=${url#https://}
  url=${url%%/*}
  url=${url%%:*}
  url=${url#www.}
  printf '%s' "$url"
}

rclone_remote_size() {
  local remote_file=$1
  local output
  output=$("${RCLONE[@]}" size "$remote_file" --json 2>/dev/null || true)
  printf '%s\n' "$output" | sed -nE 's/.*"bytes"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -n 1
}

verify_rclone_archive() {
  local archive_file=$1
  local remote_file=$2
  local archive_name=$3
  local local_size remote_size

  local_size=$(stat -c '%s' "$archive_file")
  remote_size=$(rclone_remote_size "$remote_file")

  if [[ -z "$remote_size" || "$remote_size" != "$local_size" ]]; then
    log "Verification failed for archive=${archive_name}: local_size=${local_size} remote_size=${remote_size:-missing}"
    return 1
  fi

  case "$FILES_BACKUP_VERIFY_MODE" in
    size)
      return 0
      ;;
    deep)
      "${RCLONE[@]}" cat "$remote_file" | tar -tzf - >/dev/null
      ;;
    none)
      return 0
      ;;
    *)
      die "Invalid FILES_BACKUP_VERIFY_MODE=${FILES_BACKUP_VERIFY_MODE}; use size, deep, or none"
      ;;
  esac
}

upload_archive_with_retries() {
  local archive_file=$1
  local archive_name=$2
  local remote_file="${FILES_BACKUP_RCLONE_TARGET}/${archive_name}"
  local attempt status sleep_seconds

  for ((attempt = 1; attempt <= FILES_BACKUP_UPLOAD_RETRIES; attempt++)); do
    log "Uploading archive=${archive_name} to ${FILES_BACKUP_RCLONE_TARGET} attempt=${attempt}/${FILES_BACKUP_UPLOAD_RETRIES}"

    set +e
    "${RCLONE[@]}" copyto "$archive_file" "$remote_file" \
      --retries 1 \
      --low-level-retries "$FILES_BACKUP_RCLONE_LOW_LEVEL_RETRIES" \
      --transfers 1 \
      --checkers 4
    status=$?
    set -e

    if ((status == 0)) && verify_rclone_archive "$archive_file" "$remote_file" "$archive_name"; then
      log "Verified archive=${archive_name} remote=${remote_file} mode=${FILES_BACKUP_VERIFY_MODE}"
      return 0
    fi

    if ((status != 0)); then
      log "Upload attempt ${attempt} failed with rclone exit status ${status}"
    else
      log "Upload attempt ${attempt} completed but verification failed"
    fi

    if ((attempt < FILES_BACKUP_UPLOAD_RETRIES)); then
      sleep_seconds=$((FILES_BACKUP_UPLOAD_RETRY_DELAY * attempt))
      log "Retrying archive=${archive_name} in ${sleep_seconds}s"
      sleep "$sleep_seconds"
    fi
  done

  return 1
}

preserve_failed_archive() {
  local archive_file=$1
  local archive_name=$2
  local preserved

  mkdir -p "$FILES_BACKUP_FAILED_DIR"
  chmod 700 "$FILES_BACKUP_FAILED_DIR"
  preserved="$FILES_BACKUP_FAILED_DIR/${archive_name}.failed.$(date '+%Y%m%d%H%M%S')"
  if [[ -e "$preserved" ]]; then
    preserved="${preserved}.$$"
  fi

  mv -- "$archive_file" "$preserved"
  chmod 600 "$preserved"
  log "Preserved unverified local archive at $preserved"
}

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
done < <(find "$BACKUP_WEB_ROOT" -mindepth 3 -maxdepth "$BACKUP_FIND_MAXDEPTH" -path '*/public_html/wp-config.php' -type f -print0 | sort -z)

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

if [[ "$DRY_RUN" == "false" && "$RUN_PRUNE" == "true" && "${FILES_BACKUP_RETENTION_DAYS:-0}" != "0" ]]; then
  prune_remote "$FILES_BACKUP_RCLONE_TARGET" "$FILES_BACKUP_RETENTION_DAYS"
fi

log "File backup run complete"
