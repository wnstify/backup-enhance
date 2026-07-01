#!/usr/bin/env bash
# Regression guard: the two archive layouts (public_html, contents) must exclude
# the SAME set of paths, differing only by their leading prefix. They used to be
# two hand-maintained arrays that could silently drift; build_tar_excludes()
# generates both from one list so they can't.
#
# Sources the real runner (hits its source-guard and returns before any main
# flow), then exercises build_tar_excludes() directly. No tar, no filesystem.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/enhance-files-backup.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

type build_tar_excludes >/dev/null 2>&1 || fail "build_tar_excludes is not defined"

# public_html layout
build_tar_excludes "public_html/"
public_html_args=("${tar_excludes[@]}")

# contents layout
build_tar_excludes "./"
contents_args=("${tar_excludes[@]}")

((${#public_html_args[@]} == 53)) || fail "expected 53 public_html excludes, got ${#public_html_args[@]}"
((${#contents_args[@]} == 53))    || fail "expected 53 contents excludes, got ${#contents_args[@]}"

# Drift guard: identical once each layout's prefix is stripped.
stripped_public_html=$(printf '%s\n' "${public_html_args[@]}" | sed 's#public_html/##g')
stripped_contents=$(printf '%s\n' "${contents_args[@]}" | sed 's#\./##g')
[[ "$stripped_public_html" == "$stripped_contents" ]] \
  || fail "layouts differ by more than their prefix (drift)"

# Spot-check representative entries survive with the right prefix.
printf '%s\n' "${public_html_args[@]}" | grep -qxF -- '--exclude=public_html/wp-content/cache' \
  || fail "public_html layout lost wp-content/cache exclude"
printf '%s\n' "${contents_args[@]}" | grep -qxF -- '--exclude=./wp-content/uploads/updraft' \
  || fail "contents layout lost wp-content/uploads/updraft exclude"
# Global patterns are unprefixed in both layouts.
printf '%s\n' "${public_html_args[@]}" | grep -qxF -- '--exclude=*.[wW][pP][rR][eE][sS][sS]' \
  || fail "lost case-insensitive .wpress global exclude"
printf '%s\n' "${contents_args[@]}" | grep -qxF -- '--exclude=*.zip' \
  || fail "lost unprefixed *.zip global exclude"

echo "PASS: both archive layouts generate the same excludes from one list"
