#!/usr/bin/env bash
# Behavior test for the installer's assemble_runner: inlining the shared library
# into a runner must yield a valid standalone script. This is the one genuinely
# new failure mode in the extraction — a botched inline could ship a runner that
# fails at 2am. Sources install.sh behind its source-guard, as test_install.sh does.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LIB="$SCRIPT_DIR/enhance-backup-lib.sh"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

type assemble_runner >/dev/null 2>&1 || fail "assemble_runner is not defined"

check_runner() {
  local runner=$1 out
  out=$(mktemp)
  assemble_runner "$SCRIPT_DIR/$runner" "$LIB" >"$out"

  bash -n "$out" || fail "$runner: assembled output is not valid bash"
  ! grep -qE 'source.*enhance-backup-lib' "$out" \
    || fail "$runner: assembled output still sources the library"
  ( RCLONE=(rclone)
    # shellcheck disable=SC1090
    source "$out"
    type prune_remote >/dev/null 2>&1 || exit 3
  ) || fail "$runner: sourcing assembled output does not define prune_remote"
  bash "$out" --help >/dev/null 2>&1 || fail "$runner: assembled --help did not exit 0"

  rm -f "$out"
}

check_runner enhance-db-backup.sh
check_runner enhance-files-backup.sh

echo "PASS: assembled runners are valid standalone scripts"
