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
REMOTE_USER="your_username"                       # Username for remote server (if password is used)
REMOTE_DIR="/path/to/remote/backups"              # Remote directory to store backups
REMOTE_SSH_KEY=""                                 # Optional: Path to your SSH key for passwordless login
REMOTE_MAX_BACKUPS=90                             # Maximum number of remote backups to keep

# Define Email configuration variables (Optional)
EMAIL_ENABLED=true                                # Set to true to enable email notifications
from="noreply@domain.com"                         # Replace with your desired from address
recipient="user@domain.com"                       # Replace with your desired recopient address

# Initialize log file
echo "** WordPress Backup Log - $(date +%Y-%m-%d) **" > "$LOG_FILE"

# Validate essential directories
if [[ ! -d "$SITE_ROOT" || ! -d "$BACKUP_DIR" ]]; then
   ERROR_MSG="Error: Missing required directories!"
   echo "$ERROR_MSG"
   echo "$ERROR_MSG" >> "$LOG_FILE"
   if [[ "$EMAIL_ENABLED" == "true" ]]; then
     subject="WordPress Backup of $SITE_NAME Failed - See Error for details"
     echo -e "From: $from\nTo: $recipient\nSubject: $subject\n\n$ERROR_MSG" | sendmail -f "$from" -t
   fi
   exit 1
fi

# Check for wp-config.php existence (WordPress installation check)
if [[ ! -f "$SITE_ROOT/wp-config.php" ]]; then
   ERROR_MSG="Error: Could not locate wp-config.php. Is this a valid WordPress installation?"
   echo "$ERROR_MSG"
   echo "$ERROR_MSG" >> "$LOG_FILE"
   if [[ "$EMAIL_ENABLED" == "true" ]]; then
     subject="WordPress Backup of $SITE_NAME Failed - See Error for details"
     echo -e "From: $from\nTo: $recipient\nSubject: $subject\n\n$ERROR_MSG" | sendmail -f "$from" -t
   fi
   exit 1
fi

# Extract database credentials from wp-config.php
DB_NAME=$(grep -E "DB_NAME" "$SITE_ROOT/wp-config.php" | cut -d "'" -f 4)
DB_USER=$(grep -E "DB_USER" "$SITE_ROOT/wp-config.php" | cut -d "'" -f 4)
DB_PASSWORD=$(grep -E "DB_PASSWORD" "$SITE_ROOT/wp-config.php" | cut -d "'" -f 4)
DB_HOST=$(grep -E "DB_HOST" "$SITE_ROOT/wp-config.php" | cut -d "'" -f 4)

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Backup database
mysqldump -u "$DB_USER" -p"$DB_PASSWORD" -h "$DB_HOST" "$DB_NAME" | zstd --adapt > "$BACKUP_DIR/${SITE_NAME}-wp_db-$(date +%Y-%m-%d).zst"
if [[ $? -ne 0 ]]; then
   ERROR_MSG="Error: Failed to dump database. Check wp-config credentials and permissions."
   echo "$ERROR_MSG"
   echo "$ERROR_MSG" >> "$LOG_FILE"
   if [[ "$EMAIL_ENABLED" == "true" ]]; then
     subject="WordPress Backup of $SITE_NAME Failed - See Error for details"
     echo -e "From: $from\nTo: $recipient\nSubject: $subject\n\n$ERROR_MSG" | sendmail -f "$from" -t
   fi
   exit 1
fi

# Get the size of the database backup file
db_backup_size=$(du -s --block-size=1 "$BACKUP_DIR/${SITE_NAME}-wp_db-$(date +%Y-%m-%d).zst" | awk '{print $1}')

# Check if the database backup size is less than the minimum
if [[ $db_backup_size -lt $MIN_DB_BACKUP_SIZE ]]; then
   ERROR_MSG="Error: Database backup file size ($db_backup_size bytes) is too small. Check database configuration and data."
   echo "$ERROR_MSG"
   echo "$ERROR_MSG" >> "$LOG_FILE"
   if [[ "$EMAIL_ENABLED" == "true" ]]; then
     subject="WordPress Backup of $SITE_NAME Failed - See Error for details"
     echo -e "From: $from\nTo: $recipient\nSubject: $subject\n\n$ERROR_MSG" | sendmail -f "$from" -t
   fi
   exit 1
fi

# Backup website files (excluding output)
tar -cvf "$BACKUP_DIR/${SITE_NAME}-wp_files-$(date +%Y-%m-%d).tar.zst" -C "$SITE_ROOT" .
if [[ $? -ne 0 ]]; then
   ERROR_MSG="Error: Failed to backup website files."
   echo "$ERROR_MSG"
   echo "$ERROR_MSG" >> "$LOG_FILE"
   if [[ "$EMAIL_ENABLED" == "true" ]]; then
     subject="WordPress Backup of $SITE_NAME Failed - See Error for details"
     echo -e "From: $from\nTo: $recipient\nSubject: $subject\n\n$ERROR_MSG" | sendmail -f "$from" -t
   fi
  exit 1
fi

# Get the size of the website root directory
site_root_size=$(du -s "$SITE_ROOT" | awk '{print $1}')

# Get the size of the backup file
backup_file_size=$(du -s "$BACKUP_DIR/${SITE_NAME}-wp_files-$(date +%Y-%m-%d).tar.zst" | awk '{print $1}')

# Calculate the minimum acceptable backup size (50% of website root)
min_backup_size=$((site_root_size / 2))

# Check if backup size is less than 50% of website root
if [[ $backup_file_size -lt $min_backup_size ]]; then
   ERROR_MSG="Error: Backup file size ($backup_file_size Kbytes) is less than 50% of website root size ($site_root_size Kbytes). Backup may be incomplete."
   echo "$ERROR_MSG"
   echo "$ERROR_MSG" >> "$LOG_FILE"
   if [[ "$EMAIL_ENABLED" == "true" ]]; then
     subject="WordPress Backup of $SITE_NAME Failed - See Error for details"
     echo -e "From: $from\nTo: $recipient\nSubject: $subject\n\n$ERROR_MSG" | sendmail -f "$from" -t
   fi
   exit 1
fi

# Rotate backups to keep only the last MAX_BACKUPS
ls -t "$BACKUP_DIR" | grep -E "^${SITE_NAME}-wp_(db|files|summary)-" | tail -n +$(($MAX_BACKUPS + 1)) | xargs rm -f

# Check if rsync is enabled and configured
if [[ "$RSYNC_ENABLED" == "true" ]]; then
  # Create remote directory if it doesn't exist
  ssh "$REMOTE_USER"@"$REMOTE_HOST" "mkdir -p $REMOTE_DIR" 2>/dev/null

  # Get the names of the newly created backup files
  backup_files=("$BACKUP_DIR/${SITE_NAME}-wp_db-$(date +%Y-%m-%d).zst" "$BACKUP_DIR/${SITE_NAME}-wp_files-$(date +%Y-%m-%d).tar.zst")

  # Rsync only the newly created backup files
  for file in "${backup_files[@]}"; do
    rsync -avz "$file" "$REMOTE_USER"@"$REMOTE_HOST":$REMOTE_DIR
  done

  # Rotate backups on remote server
  ssh "$REMOTE_USER"@"$REMOTE_HOST" "ls -t $REMOTE_DIR | grep -E '^${SITE_NAME}-wp_(db|files|summary)-' | tail -n +$(($MAX_BACKUPS + 1)) | xargs rm -f"

  # Check if rsync was successful
  if [[ $? -ne 0 ]]; then
    ERROR_MSG="Error: Failed to rsync backups to remote server"
    echo "$ERROR_MSG"
    echo "$ERROR_MSG" >> "$LOG_FILE"
    if [[ "$EMAIL_ENABLED" == "true" ]]; then
      subject="WordPress Backup of $SITE_NAME Failed - See Error for details"
      echo -e "From: $from\nTo: $recipient\nSubject: $subject\n\n$ERROR_MSG" | sendmail -f "$from" -t
    fi
  fi
fi

# Log success message & details
echo "** Website Backup Completed Successfully! **" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

echo "** WordPress Site Size Information:" >> "$LOG_FILE"
du -hs  "$SITE_ROOT" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

echo "** Backup Files Information:" >> "$LOG_FILE"
ls -lh "$BACKUP_DIR/${SITE_NAME}-wp_db-$(date +%Y-%m-%d).zst" >> "$LOG_FILE"
ls -lh "$BACKUP_DIR/${SITE_NAME}-wp_files-$(date +%Y-%m-%d).tar.zst" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Create the backup summary content with proper newlines for the Email body
backup_summary=$(cat << EOF
** WordPress Site Size Information:
$(du -hs "$SITE_ROOT")

** Backup Files Information:
* Database Backup File:
$(ls -lh "$BACKUP_DIR/${SITE_NAME}-wp_db-$(date +%Y-%m-%d).zst" | awk '{print $5,$9}')
* Site Backup File:
$(ls -lh "$BACKUP_DIR/${SITE_NAME}-wp_files-$(date +%Y-%m-%d).tar.zst" | awk '{print $5,$9}')
EOF
)

if [[ "$EMAIL_ENABLED" == "true" ]]; then
  echo "** Sending backup log via email... **" >> "$LOG_FILE"
  subject="WordPress Backup of $SITE_NAME Successful"  # Update subject to indicate success or error
  echo -e "From: $from\nTo: $recipient\nSubject: $subject\n\n$backup_summary" | sendmail -f "$from" -t
fi

# Exit script cleanly
exit 0
