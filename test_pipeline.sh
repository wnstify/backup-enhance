#!/usr/bin/env bash
# Behavior test for the remote upload pipeline the library now owns and the
# generic-global contract it reads. The library must define every pipeline
# function, each must honor the generic globals (not a runner's BACKUP_* /
# FILES_BACKUP_* prefix), neither runner may still carry a local copy, and each
# runner must map its own prefix onto the seven generic globals.
#
# Runs the real functions against a stub `rclone` that reports a controllable
# remote size and copy status. No server, no B2, no filesystem beyond a tmpdir.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LIB="$SCRIPT_DIR/enhance-backup-lib.sh"
# shellcheck disable=SC1090
source "$LIB"

STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT

# Stub rclone: `size --json` echoes $STUB_REMOTE_BYTES; `copyto` records its args
# and exits $STUB_COPY_STATUS. Both env vars are exported so the stub sees them.
cat >"$STUB_DIR/rclone" <<EOF
#!/usr/bin/env bash
case "\$1" in
  size)   printf '{"count":1,"bytes":%s}\n' "\${STUB_REMOTE_BYTES:-0}" ;;
  copyto) printf '%s\n' "\$*" >>"$STUB_DIR/copyto.args"; exit "\${STUB_COPY_STATUS:-0}" ;;
esac
EOF
chmod +x "$STUB_DIR/rclone"

# Stub GNU `stat -c %s` (the runners target Linux; the test host may be BSD/macOS).
cat >"$STUB_DIR/stat" <<'EOF'
#!/usr/bin/env bash
wc -c <"${!#}" | tr -d ' '
EOF
chmod +x "$STUB_DIR/stat"
export PATH="$STUB_DIR:$PATH"
RCLONE=(rclone)

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); }

# --- Behavior 1: the library defines every pipeline function -----------------
for fn in rclone_remote_size verify_rclone_archive upload_archive_with_retries \
          preserve_failed_archive; do
  [[ "$(type -t "$fn")" == function ]] || fail "library does not define $fn"; ok
done

# --- Behavior 2: rclone_remote_size parses bytes from `rclone size --json` ----
export STUB_REMOTE_BYTES=4242
[[ "$(rclone_remote_size b2:bucket/x)" == 4242 ]] || fail "rclone_remote_size: byte parse"; ok

# --- Behavior 3: verify_rclone_archive honors the generic VERIFY_MODE ---------
archive="$STUB_DIR/a.tar.gz"
printf 'abcd' >"$archive"   # 4 bytes
VERIFY_MODE=size
export STUB_REMOTE_BYTES=4
verify_rclone_archive "$archive" b2:bucket/x a.tar.gz || fail "verify: size match should pass"; ok
export STUB_REMOTE_BYTES=99
! verify_rclone_archive "$archive" b2:bucket/x a.tar.gz || fail "verify: size mismatch should fail"; ok

# --- Behavior 4: upload targets $RCLONE_TARGET and honors UPLOAD_RETRIES ------
RCLONE_TARGET=b2:bucket/db
UPLOAD_RETRIES=2
UPLOAD_RETRY_DELAY=0
LOW_LEVEL_RETRIES=3
VERIFY_MODE=size
export STUB_REMOTE_BYTES=4

: >"$STUB_DIR/copyto.args"
( export STUB_COPY_STATUS=0
  upload_archive_with_retries "$archive" a.tar.gz ) || fail "upload: success path should return 0"; ok
grep -qF -- 'b2:bucket/db/a.tar.gz' "$STUB_DIR/copyto.args" || fail "upload: wrong RCLONE_TARGET destination"; ok

: >"$STUB_DIR/copyto.args"
( export STUB_COPY_STATUS=1
  ! upload_archive_with_retries "$archive" a.tar.gz ) || fail "upload: all-fail path should return non-zero"; ok
(($(grep -c . "$STUB_DIR/copyto.args") == 2)) || fail "upload: should retry UPLOAD_RETRIES times"; ok

# --- Behavior 5: preserve_failed_archive uses the generic FAILED_DIR ----------
FAILED_DIR="$STUB_DIR/failed"
doomed="$STUB_DIR/doomed.tar.gz"
printf 'x' >"$doomed"
preserve_failed_archive "$doomed" doomed.tar.gz || fail "preserve: should succeed"; ok
compgen -G "$FAILED_DIR/doomed.tar.gz.failed.*" >/dev/null || fail "preserve: archive not moved into FAILED_DIR"; ok
[[ ! -e "$doomed" ]] || fail "preserve: original archive should be gone"; ok

# --- Behavior 6: neither runner defines the pipeline functions locally --------
for runner in enhance-db-backup.sh enhance-files-backup.sh; do
  for fn in rclone_remote_size verify_rclone_archive upload_archive_with_retries \
            preserve_failed_archive; do
    grep -qE "^${fn}\(\)" "$SCRIPT_DIR/$runner" \
      && fail "$runner still defines $fn locally"; ok
  done
done

# --- Behavior 7: each runner maps its prefix onto the seven generic globals ---
for g in RCLONE_TARGET VERIFY_MODE UPLOAD_RETRIES UPLOAD_RETRY_DELAY \
         LOW_LEVEL_RETRIES FAILED_DIR RETENTION_DAYS; do
  grep -qE "^${g}=\\\$BACKUP_" "$SCRIPT_DIR/enhance-db-backup.sh" \
    || fail "db runner does not map $g from BACKUP_*"; ok
  grep -qE "^${g}=\\\$FILES_BACKUP_" "$SCRIPT_DIR/enhance-files-backup.sh" \
    || fail "files runner does not map $g from FILES_BACKUP_*"; ok
done

echo "PASS: $pass checks"
