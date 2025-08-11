#!/bin/bash

# Copyright (c) 2024-2025 Rámon van Raaij

# License: MIT

# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu

# backup_wordpress.sh
# This script automates WordPress website backups.
# - Creates compressed backups of both the database and website files using Zstandard compression.
# - Checks for errors during the backup process and logs detailed information.
# - Optionally sends email notifications for backup success or failure.
# - Rotates backups locally and optionally on a remote server.
# - Configurable options include site name, paths, email settings, and remote server details.
#
# Crontab example:
#  0 1   *   *   *    /path_to_script/backup_wordpress.sh >/dev/null 2>&1

# Define configuration variables
SITE_NAME="www.domain.com"                        # Site name (customize as needed)
SITE_ROOT="$HOME/public_html"                     # Path to your WordPress root directory
BACKUP_DIR="$HOME/backups"                        # Location to store backups
MIN_DB_BACKUP_SIZE=512000                         # Minimum allowed database backup size in bytes, script will error if the database backup size is less than this
LOG_FILE="$BACKUP_DIR/${SITE_NAME}-wp-backup.log" # Path for the log file
MAX_BACKUPS=5                                     # Maximum number of backups to keep

# Define Remote Server rsync configuration variables (Optional)
RSYNC_ENABLED=false                               # Set to true to enable rsync to remote server
REMOTE_HOST="your_remote_server.com"              # Remote server hostname
REMOTE_USER="your_username"                       # Username for remote server
REMOTE_DIR="/path/to/remote/backups"              # Remote directory to store backups
REMOTE_SSH_KEY=""                                 # Optional: Path to your SSH key for passwordless login
REMOTE_MAX_BACKUPS=10                             # Maximum number of remote backups to keep

# Define Email configuration variables (Optional)
EMAIL_ENABLED=false                               # Set to true to enable email notifications
from="noreply@domain.com"                         # Replace with your desired from address
recipient="user@domain.com"                       # Replace with your desired recipient address

#!/bin/bash

# Copyright (c) 2024 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu

# backup_wordpress.sh
# This script automates WordPress website backups.
# - Creates compressed backups of both the database and website files using Zstandard compression.
# - Checks for errors during the backup process and logs detailed information.
# - Optionally sends email notifications for backup success or failure.
# - Rotates backups locally and optionally on a remote server.
# - Configurable options include site name, paths, email settings, and remote server details.
#
# Crontab example:
#  0 1   *   *   *    /path_to_script/backup_wordpress.sh >/dev/null 2>&1

# Define configuration variables
SITE_NAME="ramon.vanraaij.eu"                          # Site name (customize as needed)
SITE_ROOT="/var/www/wordpress"                         # Path to your WordPress root directory
BACKUP_DIR="/root/backups"                             # Location to store backups
MIN_DB_BACKUP_SIZE=400000                              # Minimum allowed database backup size in bytes, script will error if the database backup size is less than this
LOG_FILE="$BACKUP_DIR/${SITE_NAME}-wp-backup.log"      # Path for the log file
MAX_BACKUPS=5                                          # Maximum number of backup SETS to keep

# Define Remote Server rsync configuration variables (Optional)
RSYNC_ENABLED=true                                     # Set to true to enable rsync to remote server
REMOTE_HOST="192.168.0.100"                            # Remote server hostname
REMOTE_USER="backup"                                   # Username for remote server (if password is used)
REMOTE_DIR="/share/CACHEDEV1_DATA/Backups/websites"    # Remote directory to store backups
REMOTE_SSH_KEY="/root/.ssh/id_rsa"                     # Optional: Path to your SSH key for passwordless login
REMOTE_MAX_BACKUPS=90                                  # Maximum number of remote backup SETS to keep

# Define Email configuration variables (Optional)
EMAIL_ENABLED=true                                     # Set to true to enable email notifications
from="noreply@brightberry.nl"                          # Replace with your desired from address
recipient="ramon@vanraaij.eu"                          # Replace with your desired recopient address

# --- SCRIPT START ---

# Function for handling errors
handle_error() {
    local ERROR_MSG="$1"
    echo "$ERROR_MSG"
    echo "$ERROR_MSG" >> "$LOG_FILE"
    if [[ "$EMAIL_ENABLED" == "true" ]]; then
        local subject="WordPress Backup of $SITE_NAME Failed - See Error for details"
        echo -e "From: $from\nTo: $recipient\nSubject: $subject\n\n$ERROR_MSG" | sendmail -f "$from" -t
    fi
    exit 1
}

# Create backup directory and initialize log file
mkdir -p "$BACKUP_DIR"
echo "** WordPress Backup Log - $(date +%Y-%m-%d) **" > "$LOG_FILE"

# Validate essential directories
if [[ ! -d "$SITE_ROOT" || ! -d "$BACKUP_DIR" ]]; then
    handle_error "Error: Missing required directories ($SITE_ROOT or $BACKUP_DIR)."
fi

# Check for wp-config.php existence (WordPress installation check)
if [[ ! -f "$SITE_ROOT/wp-config.php" ]]; then
    handle_error "Error: Could not locate wp-config.php. Is this a valid WordPress installation?"
fi

# Extract database credentials from wp-config.php
DB_NAME=$(grep "DB_NAME" "$SITE_ROOT/wp-config.php" | cut -d "'" -f 4)
DB_USER=$(grep "DB_USER" "$SITE_ROOT/wp-config.php" | cut -d "'" -f 4)
DB_PASSWORD=$(grep "DB_PASSWORD" "$SITE_ROOT/wp-config.php" | cut -d "'" -f 4)
DB_HOST=$(grep "DB_HOST" "$SITE_ROOT/wp-config.php" | cut -d "'" -f 4)

# Define date stamp and filenames
DATE_STAMP=$(date +%Y-%m-%d)
DB_BACKUP_FILE="$BACKUP_DIR/${SITE_NAME}-wp_db-${DATE_STAMP}.zst"
FILES_BACKUP_FILE="$BACKUP_DIR/${SITE_NAME}-wp_files-${DATE_STAMP}.tar.zst"

# Backup database
mysqldump -u "$DB_USER" -p"$DB_PASSWORD" -h "$DB_HOST" "$DB_NAME" | zstd --adapt > "$DB_BACKUP_FILE"
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    handle_error "Error: Failed to dump database. Check wp-config credentials and permissions."
fi

# Get the size of the database backup file
db_backup_size=$(stat -c%s "$DB_BACKUP_FILE")

# Check if the database backup size is less than the minimum
if [[ $db_backup_size -lt $MIN_DB_BACKUP_SIZE ]]; then
    handle_error "Error: Database backup file size ($db_backup_size bytes) is too small. Check database configuration and data."
fi

# Backup website files
# CORRECTED: Piped tar to zstd for actual compression and removed -v flag.
tar -cf - -C "$SITE_ROOT" . | zstd --adapt > "$FILES_BACKUP_FILE"
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    handle_error "Error: Failed to backup website files."
fi

# Get the size of the website root directory
site_root_size=$(du -sk "$SITE_ROOT" | awk '{print $1}')

# Get the size of the backup file
backup_file_size=$(du -k "$FILES_BACKUP_FILE" | awk '{print $1}')

# Calculate the minimum acceptable backup size (50% of website root)
min_backup_size=$((site_root_size / 2))

# Check if backup size is less than 50% of website root
if [[ $backup_file_size -lt $min_backup_size ]]; then
    handle_error "Error: Backup file size ($backup_file_size Kbytes) is less than 50% of website root size ($site_root_size Kbytes). Backup may be incomplete."
fi

# Rotate local backups
# CORRECTED: The rotation logic now correctly calculates the number of files to keep (2 * MAX_BACKUPS).
# Using `find` is safer than parsing `ls`.
echo "Rotating local backups... keeping last $MAX_BACKUPS sets." >> "$LOG_FILE"
find "$BACKUP_DIR" -maxdepth 1 -type f -name "${SITE_NAME}-wp_*" | sort -r | tail -n +$((2 * MAX_BACKUPS + 1)) | xargs -r rm -f

# Check if rsync is enabled and configured
if [[ "$RSYNC_ENABLED" == "true" ]]; then
    ssh "$REMOTE_USER"@"$REMOTE_HOST" "mkdir -p $REMOTE_DIR"
    
    # Rsync only the newly created backup files
    rsync -avz "$DB_BACKUP_FILE" "$REMOTE_USER"@"$REMOTE_HOST":"$REMOTE_DIR"
    if [[ $? -ne 0 ]]; then
        handle_error "Error: Failed to rsync database backup to remote server."
    fi

    rsync -avz "$FILES_BACKUP_FILE" "$REMOTE_USER"@"$REMOTE_HOST":"$REMOTE_DIR"
    if [[ $? -ne 0 ]]; then
        handle_error "Error: Failed to rsync files backup to remote server."
    fi

    # Rotate backups on remote server
    # CORRECTED: Using REMOTE_MAX_BACKUPS and correct file count logic.
    echo "Rotating remote backups... keeping last $REMOTE_MAX_BACKUPS sets." >> "$LOG_FILE"
    ssh "$REMOTE_USER"@"$REMOTE_HOST" "find $REMOTE_DIR -maxdepth 1 -type f -name '${SITE_NAME}-wp_*' | sort -r | tail -n +$((2 * REMOTE_MAX_BACKUPS + 1)) | xargs -r rm -f"
    if [[ $? -ne 0 ]]; then
        # This is a non-critical error, so we'll log it but not exit
        echo "Warning: Failed to rotate backups on remote server." >> "$LOG_FILE"
    fi
fi

# Log success message & details
{
    echo "** Website Backup Completed Successfully! **"
    echo ""
    echo "** WordPress Site Size Information:"
    du -sh "$SITE_ROOT"
    echo ""
    echo "** Backup Files Information:"
    ls -lh "$DB_BACKUP_FILE"
    ls -lh "$FILES_BACKUP_FILE"
    echo ""
} >> "$LOG_FILE"


# Create the backup summary content for the Email body
backup_summary=$(cat << EOF
** WordPress Site Size Information:
$(du -sh "$SITE_ROOT")

** Backup Files Information:
* Database Backup File:
$(ls -lh "$DB_BACKUP_FILE" | awk '{print $5,$9}')
* Site Backup File:
$(ls -lh "$FILES_BACKUP_FILE" | awk '{print $5,$9}')
EOF
)

if [[ "$EMAIL_ENABLED" == "true" ]]; then
    echo "** Sending backup log via email... **" >> "$LOG_FILE"
    subject="WordPress Backup of $SITE_NAME Successful"
    echo -e "From: $from\nTo: $recipient\nSubject: $subject\n\n$backup_summary" | sendmail -f "$from" -t
fi

# Exit script cleanly
exit 0
