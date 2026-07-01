#!/usr/bin/env bash
# Behavior test for the parsing/infra helpers the library now owns. Sourcing the
# library standalone must define every shared helper, each must parse as before,
# and neither runner may still carry a local copy (a stale duplicate would
# silently shadow the library and let the two drift apart again).
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LIB="$SCRIPT_DIR/enhance-backup-lib.sh"
# shellcheck disable=SC1090
source "$LIB"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); }

# --- Behavior 1: the library defines every shared helper ---------------------
for fn in log die require_command quote_identifier extract_define \
          extract_table_prefix site_host_from_url sanitize_slug discover_wp_configs; do
  [[ "$(type -t "$fn")" == function ]] || fail "library does not define $fn"; ok
done

# --- Behavior 2: parsing helpers behave as before ----------------------------
[[ "$(quote_identifier 'wp`db')" == '`wp``db`' ]] || fail "quote_identifier: backtick not doubled"; ok

wpconfig=$(mktemp)
cat >"$wpconfig" <<'PHP'
<?php
define( 'DB_NAME', 'sitedb' );
define('DB_HOST', 'localhost');
$table_prefix = 'wp7_';
PHP
[[ "$(extract_define DB_NAME "$wpconfig")" == 'sitedb' ]] || fail "extract_define DB_NAME"; ok
[[ "$(extract_define DB_HOST "$wpconfig")" == 'localhost' ]] || fail "extract_define DB_HOST"; ok
[[ "$(extract_table_prefix "$wpconfig")" == 'wp7_' ]] || fail "extract_table_prefix"; ok
rm -f "$wpconfig"

[[ "$(site_host_from_url 'https://www.Example.com/wp/')" == 'Example.com' ]] \
  || fail "site_host_from_url: should strip scheme/path/www"; ok

BACKUP_NAME_MODE=first-label
[[ "$(sanitize_slug 'www.Example.COM')" == 'example' ]] || fail "sanitize_slug first-label"; ok
BACKUP_NAME_MODE=full-domain
[[ "$(sanitize_slug 'www.Example.COM')" == 'example.com' ]] || fail "sanitize_slug full-domain"; ok

# --- Behavior 3: discover_wp_configs finds public_html/wp-config.php ----------
web_root=$(mktemp -d)
mkdir -p "$web_root/site-a/public_html" "$web_root/site-b/public_html" "$web_root/site-b/other"
: >"$web_root/site-a/public_html/wp-config.php"
: >"$web_root/site-b/public_html/wp-config.php"
: >"$web_root/site-b/other/wp-config.php"   # not under public_html: must be ignored
BACKUP_WEB_ROOT="$web_root" BACKUP_FIND_MAXDEPTH=4 found=$(discover_wp_configs | tr '\0' '\n')
[[ "$found" == *"site-a/public_html/wp-config.php"* ]] || fail "discover_wp_configs missed site-a"; ok
[[ "$found" == *"site-b/public_html/wp-config.php"* ]] || fail "discover_wp_configs missed site-b"; ok
[[ "$found" != *"/other/wp-config.php"* ]] || fail "discover_wp_configs matched outside public_html"; ok
rm -rf "$web_root"

# --- Behavior 4: neither runner defines these helpers locally anymore ---------
for runner in enhance-db-backup.sh enhance-files-backup.sh; do
  for fn in log die require_command quote_identifier extract_define \
            extract_table_prefix site_host_from_url sanitize_slug discover_wp_configs; do
    grep -qE "^${fn}\(\)" "$SCRIPT_DIR/$runner" \
      && fail "$runner still defines $fn locally"; ok
  done
done

echo "PASS: $pass checks"
