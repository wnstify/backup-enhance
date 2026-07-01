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

# Remote upload pipeline. Reads the generic-global contract: RCLONE, RCLONE_TARGET,
# VERIFY_MODE, UPLOAD_RETRIES, UPLOAD_RETRY_DELAY, LOW_LEVEL_RETRIES, FAILED_DIR.
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

  case "$VERIFY_MODE" in
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
      die "Invalid VERIFY_MODE=${VERIFY_MODE}; use size, deep, or none"
      ;;
  esac
}

upload_archive_with_retries() {
  local archive_file=$1
  local archive_name=$2
  local remote_file="${RCLONE_TARGET}/${archive_name}"
  local attempt status sleep_seconds

  for ((attempt = 1; attempt <= UPLOAD_RETRIES; attempt++)); do
    log "Uploading archive=${archive_name} to ${RCLONE_TARGET} attempt=${attempt}/${UPLOAD_RETRIES}"

    set +e
    "${RCLONE[@]}" copyto "$archive_file" "$remote_file" \
      --retries 1 \
      --low-level-retries "$LOW_LEVEL_RETRIES" \
      --transfers 1 \
      --checkers 4
    status=$?
    set -e

    if ((status == 0)) && verify_rclone_archive "$archive_file" "$remote_file" "$archive_name"; then
      log "Verified archive=${archive_name} remote=${remote_file} mode=${VERIFY_MODE}"
      return 0
    fi

    if ((status != 0)); then
      log "Upload attempt ${attempt} failed with rclone exit status ${status}"
    else
      log "Upload attempt ${attempt} completed but verification failed"
    fi

    if ((attempt < UPLOAD_RETRIES)); then
      sleep_seconds=$((UPLOAD_RETRY_DELAY * attempt))
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

  mkdir -p "$FAILED_DIR"
  chmod 700 "$FAILED_DIR"
  preserved="$FAILED_DIR/${archive_name}.failed.$(date '+%Y%m%d%H%M%S')"
  if [[ -e "$preserved" ]]; then
    preserved="${preserved}.$$"
  fi

  mv -- "$archive_file" "$preserved"
  chmod 600 "$preserved"
  log "Preserved unverified local archive at $preserved"
}
