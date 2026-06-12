# Manual Database Restore

## What To Download

Backups are plain `.tar.gz` files in Backblaze B2.

Example:

```text
testing1_12-6-26_18-05.tar.gz
```

The Backblaze `b2` CLI and restic are not required.

## Option 1: Download In Browser

1. Log in to Backblaze.
2. Open the backup bucket.
3. Open the backup folder, for example:

```text
database-backups/server-name
```

4. Download the correct `.tar.gz` file.

## Option 2: Download With Rclone

### macOS

Install Homebrew if needed:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Install rclone:

```bash
brew install rclone
```

### Windows

Install rclone with WinGet:

```powershell
winget install -e --id Rclone.Rclone
```

### Configure Rclone

Run:

```bash
rclone config
```

Create a new remote:

```text
name: b2
Storage: b2
account: YOUR_B2_KEY_ID
key: YOUR_B2_APPLICATION_KEY
```

Leave other options at their defaults unless your provider gives different
values.

### List Backups

macOS:

```bash
rclone lsf b2:YOUR_BUCKET/database-backups/server-name
```

Windows PowerShell:

```powershell
rclone lsf b2:YOUR_BUCKET/database-backups/server-name
```

### Download One Backup

macOS:

```bash
rclone copyto b2:YOUR_BUCKET/database-backups/server-name/testing1_12-6-26_18-05.tar.gz ./testing1_restore.tar.gz
```

Windows PowerShell:

```powershell
rclone copyto b2:YOUR_BUCKET/database-backups/server-name/testing1_12-6-26_18-05.tar.gz .\testing1_restore.tar.gz
```

## Extract SQL

macOS:

```bash
mkdir restore
tar -xzf testing1_restore.tar.gz -C restore
ls -la restore
```

Windows PowerShell:

```powershell
mkdir restore
tar -xzf testing1_restore.tar.gz -C restore
dir restore
```

Expected files:

```text
metadata.txt
DATABASE_NAME.sql
```

## Upload SQL To Server

macOS:

```bash
scp restore/DATABASE_NAME.sql USER@SERVER:/path/to/site/
```

Windows PowerShell:

```powershell
scp .\restore\DATABASE_NAME.sql USER@SERVER:/path/to/site/
```

## Import With WP-CLI

SSH into the website/container, then run:

```bash
cd /path/to/site/public_html
wp db import ../DATABASE_NAME.sql
```

## Verify

```bash
wp db check
wp option get siteurl
wp option get home
```

## Important

Restoring an old database overwrites newer data. On WooCommerce sites, this can
remove orders, customers, stock changes, and settings created after the backup
time.
