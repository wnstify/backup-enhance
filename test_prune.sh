#!/usr/bin/env bash
# Regression guard: retention prune must PERMANENTLY delete on versioned
# Backblaze B2 (pass --b2-hard-delete). Without it, `rclone delete` only writes
# a hide-marker and the old object version bills forever.
#
# Runs the real prune_remote() from each runner against a stub `rclone` that
# records its arguments. No server, no B2, no bash 4 needed: sourcing hits the
# runner's source-guard and returns before any main-flow side effects.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT

CALL_LOG="$STUB_DIR/rclone.args"
cat >"$STUB_DIR/rclone" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALL_LOG"
EOF
chmod +x "$STUB_DIR/rclone"
export PATH="$STUB_DIR:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }

check_runner() {
  local runner=$1 target=$2
  : >"$CALL_LOG"
  (
    # shellcheck disable=SC2034  # consumed by the sourced runner's prune_remote
    RCLONE=(rclone)
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/$runner"
    prune_remote "$target" 7
  ) || fail "$runner: prune_remote missing or errored"

  grep -q -- 'delete' "$CALL_LOG"          || fail "$runner: prune did not call rclone delete"
  grep -q -- '--b2-hard-delete' "$CALL_LOG" || fail "$runner: prune did not pass --b2-hard-delete (soft-delete leaks B2 versions)"
  grep -q -- '--min-age 7d' "$CALL_LOG"    || fail "$runner: prune lost the --min-age retention window"
}

check_runner enhance-db-backup.sh    "b2:bucket/database-backups/host"
check_runner enhance-files-backup.sh "b2:bucket/file-backups/host"

echo "PASS: both runners hard-delete on prune"
