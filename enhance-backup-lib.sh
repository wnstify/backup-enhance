#!/usr/bin/env bash
# Shared backup library: pure function definitions, no top-level execution.
# Both runners source this file next to them in a clone; the installer inlines
# it so each installed runner stays a single standalone script.
#
# Generic-global config contract each runner sets before calling these:
#   RCLONE  RCLONE_TARGET  VERIFY_MODE  UPLOAD_RETRIES  UPLOAD_RETRY_DELAY
#   LOW_LEVEL_RETRIES  FAILED_DIR  RETENTION_DAYS
# The parsing/discovery helpers below either take their inputs as parameters or
# read globals whose names are identical in both runners: BACKUP_NAME_MODE
# (sanitize_slug) and BACKUP_WEB_ROOT / BACKUP_FIND_MAXDEPTH (discover_wp_configs).

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

# Emit a NUL-separated, sorted list of WordPress wp-config.php paths under the
# web root. The array-population loop and empty-check stay in each runner.
discover_wp_configs() {
  find "$BACKUP_WEB_ROOT" -mindepth 3 -maxdepth "$BACKUP_FIND_MAXDEPTH" -path '*/public_html/wp-config.php' -type f -print0 | sort -z
}

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

# Permanently delete remote archives older than the retention window.
# --b2-hard-delete removes the B2 object version instead of only hiding it;
# without it, versioned buckets keep (and bill for) every "deleted" archive.
prune_remote() {
  local target=$1 retention_days=$2
  log "Deleting remote archives older than ${retention_days}d from ${target}"
  "${RCLONE[@]}" delete "$target" --b2-hard-delete --include '*.tar.gz' --min-age "${retention_days}d"
}
