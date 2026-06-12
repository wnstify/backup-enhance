#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE=${ENV_FILE:-/etc/enhance-db-backup/env}
DRY_RUN=false
RUN_PRUNE=true
ORIGINAL_ARGS=("$@")

usage() {
  cat <<'USAGE'
Usage: enhance-db-backup [--dry-run] [--no-prune]

Discovers WordPress wp-config.php files under /var/www, dumps each local MariaDB
database via root socket authentication, uploads plain tar.gz archives with
rclone, verifies the remote object, and removes local archives only after
successful verification.

Options:
  --dry-run    Show discovered sites/databases without dumping or uploading.
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

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"
}

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
BACKUP_TMP_PARENT=${BACKUP_TMP_PARENT:-/var/tmp/enhance-db-backup}
BACKUP_FAILED_DIR=${BACKUP_FAILED_DIR:-$BACKUP_TMP_PARENT/failed}
BACKUP_DATE_FORMAT=${BACKUP_DATE_FORMAT:-%-d-%-m-%y_%H-%M}
BACKUP_NAME_MODE=${BACKUP_NAME_MODE:-first-label}
BACKUP_MYSQL_USER=${BACKUP_MYSQL_USER:-root}
BACKUP_MYSQL_SOCKET=${BACKUP_MYSQL_SOCKET:-/run/mysqld/mysqld.sock}
BACKUP_LOCK_MODE=${BACKUP_LOCK_MODE:-auto}
BACKUP_RCLONE_CONFIG=${BACKUP_RCLONE_CONFIG:-/etc/enhance-db-backup/rclone.conf}
BACKUP_RCLONE_TARGET=${BACKUP_RCLONE_TARGET:-}
BACKUP_UPLOAD_RETRIES=${BACKUP_UPLOAD_RETRIES:-3}
BACKUP_UPLOAD_RETRY_DELAY=${BACKUP_UPLOAD_RETRY_DELAY:-30}
BACKUP_RCLONE_LOW_LEVEL_RETRIES=${BACKUP_RCLONE_LOW_LEVEL_RETRIES:-3}
BACKUP_VERIFY_MODE=${BACKUP_VERIFY_MODE:-size}
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-30}

require_command date
require_command find
require_command mariadb
require_command sed
require_command tr
if [[ "$DRY_RUN" == "false" ]]; then
  require_command grep
  require_command mariadb-dump
  require_command mktemp
  require_command rclone
  require_command stat
  require_command tar
fi

[[ -d "$BACKUP_WEB_ROOT" ]] || die "Website root does not exist: $BACKUP_WEB_ROOT"
if [[ "$DRY_RUN" == "false" ]]; then
  [[ -r "$BACKUP_RCLONE_CONFIG" ]] || die "Rclone config is missing or unreadable: $BACKUP_RCLONE_CONFIG"
  [[ -n "$BACKUP_RCLONE_TARGET" ]] || die "BACKUP_RCLONE_TARGET is not set"
fi

BACKUP_RCLONE_TARGET=${BACKUP_RCLONE_TARGET%/}
MYSQL=(mariadb --batch --raw --skip-column-names --user="$BACKUP_MYSQL_USER")
MYSQLDUMP=(mariadb-dump --user="$BACKUP_MYSQL_USER")
RCLONE=(rclone --config "$BACKUP_RCLONE_CONFIG")
if [[ -n "$BACKUP_MYSQL_SOCKET" ]]; then
  MYSQL+=(--socket="$BACKUP_MYSQL_SOCKET")
  MYSQLDUMP+=(--socket="$BACKUP_MYSQL_SOCKET")
fi

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

quote_string() {
  local value=${1//\'/\'\'}
  printf "'%s'" "$value"
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

is_local_db_host() {
  local host=${1:-localhost}
  host=${host%%/*}
  case "$host" in
    localhost|localhost:*|127.0.0.1|127.0.0.1:*|::1|::1:*|\[::1\]|\[::1\]:*)
      return 0
      ;;
  esac
  return 1
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

mysql_scalar() {
  local sql=$1
  "${MYSQL[@]}" --execute "$sql"
}

get_non_transactional_tables() {
  local db=$1
  local dbs
  dbs=$(quote_string "$db")
  mysql_scalar "SELECT CONCAT(table_name, ':', engine) FROM information_schema.tables WHERE table_schema = ${dbs} AND table_type = 'BASE TABLE' AND COALESCE(engine, '') NOT IN ('InnoDB') ORDER BY table_name;" 2>/dev/null || true
}

get_site_url() {
  local db=$1
  local table_prefix=$2
  local dbq tableq
  dbq=$(quote_identifier "$db")
  tableq=$(quote_identifier "${table_prefix}options")

  local home siteurl
  home=$(mysql_scalar "SELECT option_value FROM ${dbq}.${tableq} WHERE option_name = 'home' LIMIT 1;" 2>/dev/null || true)
  if [[ -n "$home" ]]; then
    printf '%s' "$home"
    return 0
  fi

  siteurl=$(mysql_scalar "SELECT option_value FROM ${dbq}.${tableq} WHERE option_name = 'siteurl' LIMIT 1;" 2>/dev/null || true)
  printf '%s' "$siteurl"
}

write_metadata() {
  local metadata_file=$1
  local site_host=$2
  local db=$3
  local table_prefix=$4
  local config_path=$5

  {
    printf 'created_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'host=%s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'site=%s\n' "$site_host"
    printf 'database=%s\n' "$db"
    printf 'table_prefix=%s\n' "$table_prefix"
    printf 'wp_config=%s\n' "$config_path"
  } >"$metadata_file"
  chmod 600 "$metadata_file"
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

  case "$BACKUP_VERIFY_MODE" in
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
      die "Invalid BACKUP_VERIFY_MODE=${BACKUP_VERIFY_MODE}; use size, deep, or none"
      ;;
  esac
}

upload_archive_with_retries() {
  local archive_file=$1
  local archive_name=$2
  local remote_file="${BACKUP_RCLONE_TARGET}/${archive_name}"
  local attempt status sleep_seconds

  for ((attempt = 1; attempt <= BACKUP_UPLOAD_RETRIES; attempt++)); do
    log "Uploading archive=${archive_name} to ${BACKUP_RCLONE_TARGET} attempt=${attempt}/${BACKUP_UPLOAD_RETRIES}"

    set +e
    "${RCLONE[@]}" copyto "$archive_file" "$remote_file" \
      --retries 1 \
      --low-level-retries "$BACKUP_RCLONE_LOW_LEVEL_RETRIES" \
      --transfers 1 \
      --checkers 4
    status=$?
    set -e

    if ((status == 0)) && verify_rclone_archive "$archive_file" "$remote_file" "$archive_name"; then
      log "Verified archive=${archive_name} remote=${remote_file} mode=${BACKUP_VERIFY_MODE}"
      return 0
    fi

    if ((status != 0)); then
      log "Upload attempt ${attempt} failed with rclone exit status ${status}"
    else
      log "Upload attempt ${attempt} completed but verification failed"
    fi

    if ((attempt < BACKUP_UPLOAD_RETRIES)); then
      sleep_seconds=$((BACKUP_UPLOAD_RETRY_DELAY * attempt))
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

  mkdir -p "$BACKUP_FAILED_DIR"
  chmod 700 "$BACKUP_FAILED_DIR"
  preserved="$BACKUP_FAILED_DIR/${archive_name}.failed.$(date '+%Y%m%d%H%M%S')"
  if [[ -e "$preserved" ]]; then
    preserved="${preserved}.$$"
  fi

  mv -- "$archive_file" "$preserved"
  chmod 600 "$preserved"
  log "Preserved unverified local archive at $preserved"
}

backup_site() {
  local config_path=$1
  local db db_host table_prefix site_url site_host slug timestamp sql_file metadata_file archive_name archive_file

  db=$(extract_define DB_NAME "$config_path")
  db_host=$(extract_define DB_HOST "$config_path")
  table_prefix=$(extract_table_prefix "$config_path")

  if [[ -z "$db" ]]; then
    log "Skipping $config_path: DB_NAME is not a simple literal"
    return 0
  fi
  if [[ -z "$table_prefix" ]]; then
    table_prefix=wp_
  fi
  if ! is_local_db_host "${db_host:-localhost}"; then
    log "Skipping $config_path: DB_HOST is not local (${db_host})"
    return 0
  fi
  if [[ -n "${SEEN_DB[$db]:-}" ]]; then
    log "Skipping $config_path: database $db was already backed up from ${SEEN_DB[$db]}"
    return 0
  fi

  site_url=$(get_site_url "$db" "$table_prefix")
  site_host=$(site_host_from_url "$site_url")
  if [[ -z "$site_host" ]]; then
    site_host=$(basename "$(dirname "$(dirname "$config_path")")")
  fi

  slug=$(sanitize_slug "$site_host")
  if [[ -n "${SEEN_SLUG[$slug]:-}" ]]; then
    slug="${slug}_$(sanitize_slug "$db")"
  fi
  SEEN_SLUG[$slug]=1
  SEEN_DB[$db]=$config_path

  timestamp=$(date "+$BACKUP_DATE_FORMAT")
  archive_name="${slug}_${timestamp}.tar.gz"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "Would back up site=${site_host} db=${db} archive=${archive_name}"
    return 0
  fi

  local site_dir
  site_dir=$(mktemp -d "$RUN_DIR/${slug}.XXXXXX")
  chmod 700 "$site_dir"

  sql_file="$site_dir/${db}.sql"
  metadata_file="$site_dir/metadata.txt"
  archive_file="$site_dir/$archive_name"

  local non_transactional_tables dump_lock_args=()
  non_transactional_tables=$(get_non_transactional_tables "$db")
  case "$BACKUP_LOCK_MODE" in
    auto)
      if [[ -n "$non_transactional_tables" ]]; then
        dump_lock_args=(--lock-tables)
        log "Dumping site=${site_host} db=${db} with table locks; non-transactional tables: ${non_transactional_tables//$'\n'/, }"
      else
        dump_lock_args=(--single-transaction --skip-lock-tables)
        log "Dumping site=${site_host} db=${db} with single transaction"
      fi
      ;;
    tables)
      dump_lock_args=(--lock-tables)
      log "Dumping site=${site_host} db=${db} with table locks"
      ;;
    none)
      dump_lock_args=(--single-transaction --skip-lock-tables)
      log "Dumping site=${site_host} db=${db} with single transaction"
      ;;
    *)
      die "Invalid BACKUP_LOCK_MODE=${BACKUP_LOCK_MODE}; use auto, tables, or none"
      ;;
  esac

  "${MYSQLDUMP[@]}" \
    "${dump_lock_args[@]}" \
    --quick \
    --routines \
    --events \
    --triggers \
    --hex-blob \
    --default-character-set=utf8mb4 \
    --skip-comments \
    --databases "$db" >"$sql_file"
  chmod 600 "$sql_file"
  write_metadata "$metadata_file" "$site_host" "$db" "$table_prefix" "$config_path"

  tar -C "$site_dir" -czf "$archive_file" "$(basename "$sql_file")" "$(basename "$metadata_file")"
  chmod 600 "$archive_file"
  rm -f -- "$sql_file" "$metadata_file"

  if ! upload_archive_with_retries "$archive_file" "$archive_name"; then
    preserve_failed_archive "$archive_file" "$archive_name"
    return 1
  fi

  rm -f -- "$archive_file"
  rmdir "$site_dir"
  log "Finished site=${site_host} archive=${archive_name}"
}

declare -a CONFIGS=()
while IFS= read -r -d '' config_path; do
  CONFIGS+=("$config_path")
done < <(find "$BACKUP_WEB_ROOT" -mindepth 3 -maxdepth "$BACKUP_FIND_MAXDEPTH" -path '*/public_html/wp-config.php' -type f -print0 | sort -z)

if ((${#CONFIGS[@]} == 0)); then
  die "No WordPress wp-config.php files found under $BACKUP_WEB_ROOT"
fi

declare -A SEEN_DB=()
declare -A SEEN_SLUG=()

if [[ "$DRY_RUN" == "false" ]]; then
  mkdir -p "$BACKUP_TMP_PARENT"
  chmod 700 "$BACKUP_TMP_PARENT"
  RUN_DIR=$(mktemp -d "$BACKUP_TMP_PARENT/run.XXXXXXXX")
  chmod 700 "$RUN_DIR"
fi

for config_path in "${CONFIGS[@]}"; do
  backup_site "$config_path"
done

if [[ "$DRY_RUN" == "false" && "$RUN_PRUNE" == "true" && "${BACKUP_RETENTION_DAYS:-0}" != "0" ]]; then
  log "Deleting remote archives older than ${BACKUP_RETENTION_DAYS}d from ${BACKUP_RCLONE_TARGET}"
  "${RCLONE[@]}" delete "$BACKUP_RCLONE_TARGET" --include '*.tar.gz' --min-age "${BACKUP_RETENTION_DAYS}d"
fi

log "Backup run complete"
