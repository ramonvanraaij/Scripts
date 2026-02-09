#!/bin/bash

# Copyright (c) 2024-2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# backup_wordpress.sh (v3 - Example Config)
# This script automates WordPress website backups with improved error handling and logging.
# - Creates compressed backups of both the database and website files using Zstandard compression.
# - Checks for errors during the backup process and logs detailed, timestamped information.
# - Appends to the log file instead of overwriting it.
# - Optionally sends email notifications for backup success or failure.
# - Rotates backups locally and optionally on a remote server.
# - Includes pre-flight checks for required commands and permissions.
#
# Crontab example:
#  0 1   * * * /path_to_script/backup_wordpress.sh

# --- CONFIGURATION ---
SITE_NAME="example.com"                        # Site name (customize as needed)
SITE_ROOT="/var/www/html"                      # Path to your WordPress root directory
BACKUP_DIR="/home/user/backups"                # Location to store backups
MIN_DB_BACKUP_SIZE=102400                      # Minimum allowed database backup size in bytes (e.g., 100KB)
LOG_FILE="$BACKUP_DIR/${SITE_NAME}-wp-backup.log" # Path for the log file
MAX_BACKUPS=7                                  # Maximum number of backup SETS to keep locally

# Remote Server rsync configuration (Optional)
RSYNC_ENABLED="false"                          # Set to true to enable rsync to remote server
REMOTE_HOST="remote-backup-server.local"       # Remote server hostname
REMOTE_USER="backupuser"                       # Username for remote server
REMOTE_DIR="/mnt/backups/websites"             # Remote directory to store backups
REMOTE_SSH_KEY="/home/user/.ssh/id_rsa"        # Path to your SSH key for passwordless login
REMOTE_MAX_BACKUPS=30                          # Maximum number of backup SETS to keep on remote server

# Email configuration (Optional)
EMAIL_ENABLED="false"                          # Set to true to enable email notifications
from="wordpress-backup@example.com"            # Replace with your desired from address
recipient="admin@example.com"                  # Replace with your desired recipient address

# --- SCRIPT START ---

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Pipelines return the exit status of the last command to fail.
set -o pipefail

# --- FUNCTIONS ---

# Function for logging with timestamp.
# Uses 'tee -a' to both display the message and append it to the log file.
log() {
    local MSG="$1"
    printf "[%s] %s\n" "$(date '+%a %b %d %H:%M:%S %Z %Y')" "$MSG" | tee -a "$LOG_FILE"
}

# Function for handling errors.
handle_error() {
    local ERROR_MSG="$1"
    log "ERROR: $ERROR_MSG"

    if [[ "$EMAIL_ENABLED" == "true" ]]; then
        local subject="WordPress Backup of $SITE_NAME Failed"
        local email_body="An error occurred during the WordPress backup for $SITE_NAME.

Error details:
$ERROR_MSG

Please check the log file for more information: $LOG_FILE"
        echo -e "From: $from\nTo: $recipient\nSubject: $subject\n\n$email_body" | sendmail -f "$from" -t
    fi
    log "--- Backup script finished with an error. ---"
    exit 1
}

# --- MAIN SCRIPT ---

# Create backup directory if it doesn't exist.
mkdir -p "$BACKUP_DIR"

log "--- Starting WordPress Backup for $SITE_NAME ---"

# Pre-flight checks
log "Performing pre-flight checks..."
# 1. Check for required commands
for cmd in mysqldump zstd tar rsync sendmail ssh; do
    if ! command -v "$cmd" &> /dev/null; then
        handle_error "Required command '$cmd' is not installed or not in PATH."
    fi
done

# 2. Validate essential directories
if [[ ! -d "$SITE_ROOT" ]]; then
    handle_error "WordPress site root directory does not exist ($SITE_ROOT)."
fi
if [[ ! -w "$BACKUP_DIR" ]]; then
    handle_error "Backup directory is not writable ($BACKUP_DIR)."
fi

# 3. Check for wp-config.php existence
if [[ ! -f "$SITE_ROOT/wp-config.php" ]]; then
    handle_error "Could not locate wp-config.php in $SITE_ROOT. Is this a valid WordPress installation?"
fi

# 4. Check for SSH key existence if rsync is enabled
if [[ "$RSYNC_ENABLED" == "true" && ! -r "$REMOTE_SSH_KEY" ]]; then
    handle_error "SSH key file is not readable or does not exist at the specified path ($REMOTE_SSH_KEY)."
fi
log "Pre-flight checks passed."

# Rotate local backups BEFORE creating new ones to prevent accidental deletion.
log "Rotating local backups... keeping last $MAX_BACKUPS sets."
find "$BACKUP_DIR" -maxdepth 1 -type f -name "${SITE_NAME}-wp_*" | sort -r | tail -n +$((2 * MAX_BACKUPS + 1)) | xargs -r rm -f
log "Local backup rotation complete."

# Extract database credentials from wp-config.php
log "Extracting database credentials from wp-config.php..."
DB_NAME=$(grep "DB_NAME" "$SITE_ROOT/wp-config.php" | cut -d "'" -f 4)
DB_USER=$(grep "DB_USER" "$SITE_ROOT/wp-config.php" | cut -d "'" -f 4)
DB_PASSWORD=$(grep "DB_PASSWORD" "$SITE_ROOT/wp-config.php" | cut -d "'" -f 4)
DB_HOST=$(grep "DB_HOST" "$SITE_ROOT/wp-config.php" | cut -d "'" -f 4)

# Validate that database credentials were extracted
if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASSWORD" || -z "$DB_HOST" ]]; then
    handle_error "Failed to extract one or more database credentials from wp-config.php."
fi
log "Successfully extracted database credentials."

# Define date stamp and filenames
DATE_STAMP=$(date +%Y-%m-%d)
DB_BACKUP_FILE="$BACKUP_DIR/${SITE_NAME}-wp_db-${DATE_STAMP}.sql.zst"
FILES_BACKUP_FILE="$BACKUP_DIR/${SITE_NAME}-wp_files-${DATE_STAMP}.tar.zst"

# Backup database
log "Starting database backup for '$DB_NAME'..."
if ! mysqldump -u "$DB_USER" -p"$DB_PASSWORD" -h "$DB_HOST" "$DB_NAME" | zstd --adapt > "$DB_BACKUP_FILE"; then
    rm -f "$DB_BACKUP_FILE" # Clean up empty/failed file
    handle_error "Database dump (mysqldump) failed. Check credentials and database server status."
fi
log "Database backup created successfully: $DB_BACKUP_FILE"

# Verify database backup size
log "Verifying database backup size..."
db_backup_size=$(stat -c%s "$DB_BACKUP_FILE")
if [[ $db_backup_size -lt $MIN_DB_BACKUP_SIZE ]]; then
    handle_error "Database backup file size ($db_backup_size bytes) is smaller than the minimum required size ($MIN_DB_BACKUP_SIZE bytes)."
fi
log "Database backup size is acceptable ($db_backup_size bytes)."

# Backup website files
log "Starting website files backup from '$SITE_ROOT'..."
if ! tar -cf - -C "$SITE_ROOT" . | zstd --adapt > "$FILES_BACKUP_FILE"; then
    rm -f "$FILES_BACKUP_FILE" # Clean up partial file
    handle_error "Website files backup (tar) failed."
fi
log "Website files backup created successfully: $FILES_BACKUP_FILE"

# Verify website files backup size
log "Verifying website files backup size..."
site_root_size_kb=$(du -sk "$SITE_ROOT" | awk '{print $1}')
backup_file_size_kb=$(du -k "$FILES_BACKUP_FILE" | awk '{print $1}')
min_backup_size_kb=$((site_root_size_kb / 4)) # 25% of original size

if [[ $backup_file_size_kb -lt $min_backup_size_kb ]]; then
    handle_error "Website files backup size ($backup_file_size_kb KB) is less than 25% of website root size ($site_root_size_kb KB). Backup may be incomplete."
fi
log "Website files backup size is acceptable ($backup_file_size_kb KB)."

# Sync to remote server
if [[ "$RSYNC_ENABLED" == "true" ]]; then
    log "Rsync to remote server is enabled."
    
    # Define the SSH command to use for both ssh and rsync.
    # Added StrictHostKeyChecking=no to avoid interactive prompts in cron.
    SSH_COMMAND="ssh -i $REMOTE_SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=no"
    
    log "Connecting to $REMOTE_USER@$REMOTE_HOST to sync backups..."

    # Ensure remote directory exists
    $SSH_COMMAND "$REMOTE_USER"@"$REMOTE_HOST" "mkdir -p '$REMOTE_DIR'"

    # Rsync the newly created backup files
    log "Syncing database backup..."
    rsync -avz --rsh="$SSH_COMMAND" "$DB_BACKUP_FILE" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR"

    log "Syncing website files backup..."
    rsync -avz --rsh="$SSH_COMMAND" "$FILES_BACKUP_FILE" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR"
    log "Rsync to remote server completed successfully."

    # Rotate backups on remote server
    log "Rotating remote backups... keeping last $REMOTE_MAX_BACKUPS sets."
    if ! $SSH_COMMAND "$REMOTE_USER"@"$REMOTE_HOST" "find '$REMOTE_DIR' -maxdepth 1 -type f -name '${SITE_NAME}-wp_*' | sort -r | tail -n +$((2 * REMOTE_MAX_BACKUPS + 1)) | xargs -r rm -f"; then
        log "Warning: Failed to rotate backups on remote server. This is a non-critical error."
    else
        log "Remote backup rotation complete."
    fi
fi

# Final success message and email
log "--- WordPress Backup for $SITE_NAME Completed Successfully! ---"

# Create the backup summary content for the Email body
backup_summary=$(cat << EOF
** WordPress Site Size Information:
$(du -sh "$SITE_ROOT")

** Backup Files Information:
* Database Backup File:
$(ls -lh "$DB_BACKUP_FILE" | awk '{print "Size: " $5 ", File: " $9}')
* Site Backup File:
$(ls -lh "$FILES_BACKUP_FILE" | awk '{print "Size: " $5 ", File: " $9}')
EOF
)

if [[ "$EMAIL_ENABLED" == "true" ]]; then
    log "Sending success notification email..."
    subject="WordPress Backup of $SITE_NAME Successful"
    echo -e "From: $from\nTo: $recipient\nSubject: $subject\n\n$backup_summary" | sendmail -f "$from" -t
fi

exit 0
