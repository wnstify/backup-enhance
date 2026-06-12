# Enhance Website Backups

This installs root-run backup jobs for Enhance servers. The database job
discovers WordPress sites under `/var/www`, dumps each local MariaDB database
through socket-auth root access, uploads a plain `.tar.gz` archive to Backblaze
B2 with rclone's native B2 backend, and removes the local archive only after
remote verification succeeds.

The files job reuses the same rclone credentials, archives each site's
`public_html` contents, preserves modes, mtimes, ACLs, and xattrs, excludes
common local backup/archive files, uploads to B2, verifies the remote object,
and removes the local archive only after verification succeeds.

## Install Database Backups First

Run from this directory:

```bash
sudo ./install.sh
```

The installer asks for:

- Backblaze application key ID
- Backblaze application key
- Backblaze bucket name
- Backup folder inside the bucket, for example `database-backups/server-name`
- `/var/www` scan path, temp directory, archive date format, and retention days
- Optional systemd timer schedule

Use a restricted Backblaze application key scoped to the backup bucket.

## Install File Backups After Database Backups

Run from this directory:

```bash
sudo ./install-files-backup.sh
```

The files installer reuses `/etc/enhance-db-backup/rclone.conf` and
`/etc/enhance-db-backup/env`. By default it changes the database target from:

```text
b2:BUCKET/database-backups/server-name
```

to:

```text
b2:BUCKET/file-backups/server-name
```

## Backup Naming

The default database archive name format is:

```text
testing1_25-5-26_18-00.tar.gz
```

The default files archive name format is:

```text
testing1_files_25-5-26_18-00.tar.gz
```

By default file archives use `FILES_BACKUP_ARCHIVE_LAYOUT=contents`. The archive
contains the contents of `public_html`, not a top-level `public_html` directory,
so a website SSH user can extract it from inside the existing `public_html`.

By default `testing1.com` becomes `testing1`. Set this in
`/etc/enhance-db-backup/env` if you prefer full domains:

```bash
BACKUP_NAME_MODE=full-domain
```

With `full-domain`, `testing1.com` becomes `testing1.com_25-5-26_18-00.tar.gz`.

## Security Model

- Database dumps use MariaDB root socket auth, so app database passwords are not
  copied into backup config.
- Secrets live in `/etc/enhance-db-backup/rclone.conf`, owned by `root:root`,
  mode `600`.
- Runtime settings live in `/etc/enhance-db-backup/env`, owned by `root:root`,
  mode `600`.
- Temporary files are created under a mode `700` working directory.
- A `.tar.gz` is written into a root-only temporary directory, uploaded with
  rclone, verified, and deleted only after verification succeeds.
- Uploads are retried with `BACKUP_UPLOAD_RETRIES`,
  `BACKUP_UPLOAD_RETRY_DELAY`, and rclone low-level retries.
- If all upload or verification attempts fail, the unverified archive is moved
  to `BACKUP_FAILED_DIR`, which defaults to
  `/var/tmp/enhance-db-backup/failed`.
- `BACKUP_VERIFY_MODE=size` verifies that the remote object exists and matches
  the local archive size. `BACKUP_VERIFY_MODE=deep` downloads the archive and
  validates the tar/gzip stream, but doubles transfer for each backup.
- `BACKUP_LOCK_MODE=auto` uses non-blocking `--single-transaction` dumps for
  all-InnoDB databases and switches to `--lock-tables` only when a database has
  non-transactional tables.
- Remote retention uses `BACKUP_RETENTION_DAYS`; `0` disables automatic remote
  deletion.
- File backups use `FILES_BACKUP_RCLONE_TARGET`,
  `FILES_BACKUP_RETENTION_DAYS`, `FILES_BACKUP_VERIFY_MODE`, and
  `FILES_BACKUP_ARCHIVE_LAYOUT`.
- For customer self-restore, keep the existing `public_html` directory in place
  and extract the archive inside it as the website SSH user.
- For root-level restores from the parent site directory, set
  `FILES_BACKUP_ARCHIVE_LAYOUT=public_html`.

## Manual Database Commands

Dry-run discovery:

```bash
sudo enhance-db-backup --dry-run
```

Run a backup:

```bash
sudo enhance-db-backup
```

List remote archives:

```bash
sudo bash -c 'set -a; . /etc/enhance-db-backup/env; set +a; rclone --config "$BACKUP_RCLONE_CONFIG" lsf "$BACKUP_RCLONE_TARGET"'
```

Systemd timer:

```bash
systemctl status enhance-db-backup.timer
journalctl -u enhance-db-backup.service
```

## Manual File Commands

Dry-run discovery:

```bash
sudo enhance-files-backup --dry-run
```

Run a backup:

```bash
sudo enhance-files-backup
```

List remote file archives:

```bash
sudo bash -c 'set -a; . /etc/enhance-db-backup/env; set +a; rclone --config "$BACKUP_RCLONE_CONFIG" lsf "$FILES_BACKUP_RCLONE_TARGET"'
```

Systemd timer:

```bash
systemctl status enhance-files-backup.timer
journalctl -u enhance-files-backup.service
```

## Restore

Use `db-restore.md` for database restores and `files-restore.md` for
owner-preserving WordPress file restores.
