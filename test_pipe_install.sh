#!/usr/bin/env bash
# Regression guard: the installer is documented to run piped from GitHub via
#   sudo bash -c "$(curl -fsSL .../install.sh)"
# In that form there is no source file, so ${BASH_SOURCE[0]} is unset. Under the
# script's own `set -u`, an unguarded reference aborts at the very first lines,
# before the installer can even fetch the runners.
#
# Reproduce the piped condition (run the script's prologue as a `bash -c`
# string, with no source file) and assert it reaches the interactive section
# without an unbound-variable error. The prologue is cut before the EUID/sudo
# re-exec, so this test never runs the real installer.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }

# Everything up to (not including) the interactive install's EUID re-exec:
# the shebang, set -u, SCRIPT_DIR, the pure functions, and the source-guard.
prologue=$(awk '/^if \(\(EUID != 0\)\); then/{exit} {print}' "$SCRIPT_DIR/install.sh")

# Run it the way `bash -c "$(curl ...)"` does: a -c string, no BASH_SOURCE.
out=$(bash -c "${prologue}"$'\n''echo PIPE_OK' 2>&1) || true

[[ "$out" != *"unbound variable"* ]] \
  || fail "install.sh aborts on an unbound variable when piped: $out"
[[ "$out" == *"PIPE_OK"* ]] \
  || fail "install.sh prologue did not reach the interactive section: $out"

echo "PASS: install.sh runs its prologue safely when piped (BASH_SOURCE unset)"
