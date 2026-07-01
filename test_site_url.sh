#!/usr/bin/env bash
# Regression guard: the files runner's site-URL lookup must connect to MariaDB
# through the operator's configured connection (BACKUP_MYSQL_SOCKET / USER, the
# same MYSQL array the db runner uses) — not a hardcoded default socket. If it
# ignores the configured socket, the files job can fail to resolve the site URL
# where the db job succeeds, and the two jobs then name the same site with
# different slugs.
#
# Sources the runner (hits its source-guard, returns before the main flow),
# then drives mysql_site_url against a stub `mariadb` that records its args.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT

ARGS_LOG="$STUB_DIR/mariadb.args"
cat >"$STUB_DIR/mariadb" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$ARGS_LOG"
printf 'https://example.com\n'
EOF
chmod +x "$STUB_DIR/mariadb"
export PATH="$STUB_DIR:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }

# shellcheck disable=SC1090
source "$SCRIPT_DIR/enhance-files-backup.sh"

type mysql_site_url >/dev/null 2>&1 || fail "mysql_site_url is not defined"

: >"$ARGS_LOG"
# The main flow builds MYSQL from BACKUP_MYSQL_*; replicate that seam here (as
# test_prune.sh does for RCLONE) with a non-default socket and user.
MYSQL=(mariadb --batch --raw --skip-column-names --user=bob --socket=/custom/mysqld.sock)
mysql_site_url sitedb wp_ >/dev/null

grep -q -- '--socket=/custom/mysqld.sock' "$ARGS_LOG" \
  || fail "site-URL lookup ignored the configured MySQL socket"
grep -q -- '--user=bob' "$ARGS_LOG" \
  || fail "site-URL lookup ignored the configured MySQL user"

echo "PASS: files site-URL lookup honors the configured MySQL connection"
