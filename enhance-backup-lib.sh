#!/usr/bin/env bash
# Shared backup library: pure function definitions, no top-level execution.
# Both runners source this file next to them in a clone; the installer inlines
# it so each installed runner stays a single standalone script.
#
# Generic-global config contract each runner sets before calling these:
#   RCLONE  RCLONE_TARGET  VERIFY_MODE  UPLOAD_RETRIES  UPLOAD_RETRY_DELAY
#   LOW_LEVEL_RETRIES  FAILED_DIR  RETENTION_DAYS
# Slice 1 moves only prune_remote; later slices widen this file.

# Permanently delete remote archives older than the retention window.
# --b2-hard-delete removes the B2 object version instead of only hiding it;
# without it, versioned buckets keep (and bill for) every "deleted" archive.
prune_remote() {
  local target=$1 retention_days=$2
  log "Deleting remote archives older than ${retention_days}d from ${target}"
  "${RCLONE[@]}" delete "$target" --b2-hard-delete --include '*.tar.gz' --min-age "${retention_days}d"
}
