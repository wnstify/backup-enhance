# Manual WordPress Files Restore

## Download

Files backups are plain `.tar.gz` archives in the configured B2 folder.

Example:

```text
testing3_files_12-6-26_19-10.tar.gz
```

Download from Backblaze, or with rclone:

```bash
rclone copyto b2:YOUR_BUCKET/file-backups/server-name/testing3_files_12-6-26_19-10.tar.gz ./testing3_files_restore.tar.gz
```

## Verify Archive

```bash
tar -tzf testing3_files_restore.tar.gz | head
```

The archive should contain files like:

```text
./wp-admin/...
./wp-content/...
./wp-config.php
```

If the archive lists `public_html/...`, do not extract it from inside
`public_html` without `--strip-components=1`. New backups created with
`FILES_BACKUP_ARCHIVE_LAYOUT=contents` do not have this problem.

## Customer Restore With SSH

Upload the archive into the existing `public_html` directory, then SSH into the
website container/user and run:

```bash
cd public_html
tar -xzf testing3_files_restore.tar.gz
rm -f testing3_files_restore.tar.gz
```

Do not delete the `public_html` directory itself. Empty or overwrite its
contents only. The existing `public_html` directory has Enhance-specific
ownership/group permissions that a normal website user cannot recreate.

## Root Restore On The Server

If restoring as root, extract into the existing `public_html` directory:

```bash
site_home=/var/www/8a59be65-8634-4d54-a3e8-ec87fe4755dc
archive=/root/testing3_files_restore.tar.gz

tar --extract --gzip --file "$archive" --directory "$site_home/public_html" --same-owner --numeric-owner --acls --xattrs --preserve-permissions
```

Then verify:

```bash
find "$site_home/public_html" -maxdepth 1 -printf '%M %u:%g %p\n'
```

## Important

Customer SSH/FTP extraction will not restore numeric owner/group. That is okay
when extracting inside the existing `public_html` as the same website user,
because WordPress files should be owned by that website user.
