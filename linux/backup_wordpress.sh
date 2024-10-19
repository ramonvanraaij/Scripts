#!/bin/bash

# Copyright (c) 2024 Rámon van Raaij

# License: MIT

# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu

# backup_wordpress.sh - This script is designed to create a compressed backup of a WordPress website. It first retrieves database credentials from the wp-config.php file, then backs up both the website's database and files using Zstandard compression. Finally, it keeps only a specified number of backups and logs the process for reference.

# Define configuration variables
SITE_NAME="www.domain.com"                        # Site name (customize as needed)
SITE_ROOT="$HOME/public_html"                     # Path to your WordPress root directory
BACKUP_DIR="$HOME/backups"                        # Location to store backups
LOG_FILE="$BACKUP_DIR/${SITE_NAME}-wp-backup.log" # Path for the log file
MAX_BACKUPS=5                                     # Maximum number of backups to keep

# Initialize log file
echo "** WordPress Backup Log - $(date +%Y-%m-%d) **" > "$LOG_FILE"

# Validate essential directories
if [[ ! -d "$SITE_ROOT" || ! -d "$BACKUP_DIR" ]]; then
  echo "Error: Missing required directories!" >> "$LOG_FILE"
  exit 1
fi

# Check for wp-config.php existence (WordPress installation check)
if [[ ! -f "$SITE_ROOT/wp-config.php" ]]; then
  echo "Error: Could not locate wp-config.php. Is this a valid WordPress installation?" >> "$LOG_FILE"
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
  echo "Error: Failed to dump database. Check wp-config credentials and permissions." >> "$LOG_FILE"
  exit 1
fi

# Backup website files (excluding output)
tar -cvf "$BACKUP_DIR/${SITE_NAME}-wp_files-$(date +%Y-%m-%d).tar.zst" -C "$SITE_ROOT" .

if [[ $? -ne 0 ]]; then
  echo "Error: Failed to backup website files." >> "$LOG_FILE"
  exit 1
fi

# Rotate backups to keep only the last MAX_BACKUPS
ls -t "$BACKUP_DIR" | grep -E "^${SITE_NAME}-wp_(db|files|summary)-" | tail -n +$(($MAX_BACKUPS + 1)) | xargs rm -f

# Log success message & details
echo "** Website Backup Completed Successfully! **" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

echo "** WordPress Site File List (Depth 2):" >> "$LOG_FILE"
du -h --max-depth 2 "$SITE_ROOT" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

echo "** Backup File Information:" >> "$LOG_FILE"
du -h "$BACKUP_DIR" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Create the backup summary content with proper newlines for the Email body
backup_summary=$(cat << EOF
** WordPress Site File List (Depth 2):**

$(du -h --max-depth 2 "$SITE_ROOT")

** Backup File Information:**

$(du -h "$BACKUP_DIR")
EOF
)

# Optional: Email notification (uncomment to enable)
#echo "** Sending backup log via email... **" >> "$LOG_FILE"
#from="noreply@domain.com"              # Replace with your desired from address
#recipient="user@domain.com"            # Replace with your desired recopient address
#subject="WordPress Backup of $SITE_NAME Successful "
#echo -e "From: $from\nTo: $recipient\nSubject: $subject\n\n$backup_summary" | sendmail -f "$from" -t

# Exit script cleanly
exit 0
