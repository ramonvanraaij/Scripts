#!/bin/bash
# pmg_backup.sh
# =================================================================
# Proxmox Mail Gateway Backup Script with Rotation and Rsync
# Copyright (c) 2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
# =================================================================
# This script performs the following actions:
# 1. Creates a backup of the PMG configuration using pmgbackup.
# 2. Rotates local backups, keeping a specified number of recent backups.
# 3. (Optional) Syncs the latest backup to a remote server via rsync over SSH.
# 4. (Optional) Rotates backups on the remote server.
# 5. (Optional) Sends an email notification upon success or failure.
#
# Usage:
# 1. Customize the variables in the "User-defined Variables" section.
# 2. Make the script executable: chmod +x /path/to/your/script/pmg_backup.sh
# 3. Schedule it with cron: crontab -e
#    Add a line like: 0 2 * * * /path/to/your/script/pmg_backup.sh
# =================================================================

# --- Script Configuration ---

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u

# --- User-defined Variables ---

# Local Backup Configuration
MAX_BACKUPS=5                                          # Maximum number of local backup files to keep.
BACKUP_DIR="/var/lib/pmg/backup"                       # The directory where pmgbackup stores files.

# Remote Server rsync Configuration
RSYNC_ENABLED="true"                                   # Set to "true" to enable rsync to remote server.
REMOTE_HOST="your.server.com"                          # Remote server hostname or IP address.
REMOTE_USER="backup"                                   # Username for the remote server.
REMOTE_DIR="/path/to/remote/backups"                   # Remote directory to store backups.
REMOTE_SSH_KEY="/root/.ssh/id_ed25519"                 # Optional: Path to your SSH key for passwordless login.
REMOTE_MAX_BACKUPS=90                                  # Maximum number of backup files to keep on the remote server.

# Email Notification Configuration
EMAIL_ENABLED="true"                                   # Set to "true" to enable email notifications.
FROM_ADDRESS="noreply@example.com"                     # The "From" address for email notifications.
RECIPIENT_ADDRESS="admin@example.com"                  # The recipient's email address.

# --- Script Internal Variables ---
LOG_MESSAGES=""
SCRIPT_STATUS="SUCCESS"
LATEST_BACKUP_FILE=""

# --- Functions ---

# Function to log messages to the console and a variable for the email body.
log_message() {
    local message="$1"
    # Log to console with timestamp
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message"
    # Append to log variable for email
    LOG_MESSAGES+="$(date '+%Y-%m-%d %H:%M:%S') - $message"$'\n'
}

# Function to send the final email notification.
send_notification() {
    if [[ "$EMAIL_ENABLED" != "true" ]]; then
        return
    fi

    local subject="PMG Backup Status: $SCRIPT_STATUS on $(hostname)"
    
    # Check if the 'mail' command is available.
    if ! command -v mail &> /dev/null; then
        log_message "ERROR: 'mail' command not found. Cannot send email. Please install mailutils."
        return
    fi
    
    log_message "Sending email notification to $RECIPIENT_ADDRESS..."
    # Pipe the collected log messages into the body of the email.
    echo -e "$LOG_MESSAGES" | mail -s "$subject" -a "From: $FROM_ADDRESS" "$RECIPIENT_ADDRESS"
}

# Function to handle script exit, both successful and on error.
# This function is called by the 'trap' command.
cleanup() {
    local exit_status=$?
    
    # If the script exits with an error (exit_status != 0) and we haven't already
    # set the status to FAILURE, we update the status now. This is a fallback.
    if [[ $exit_status -ne 0 && "$SCRIPT_STATUS" == "SUCCESS" ]]; then
        SCRIPT_STATUS="FAILURE"
        log_message "ERROR: Script exited unexpectedly with status $exit_status. An error occurred."
    fi
    
    log_message "Backup process finished with final status: $SCRIPT_STATUS"
    send_notification
}

# --- Main Script Logic ---

# Register the cleanup function to be called on any script exit.
trap cleanup EXIT

log_message "Starting Proxmox Mail Gateway backup process..."

# Step 1: Create the backup using pmgbackup
# -----------------------------------------------------------------
log_message "Creating local PMG backup..."

# Capture output and handle errors in a way that is safe with 'set -e'.
if ! BACKUP_OUTPUT=$(pmgbackup backup 2>&1); then
    SCRIPT_STATUS="FAILURE"
    log_message "FATAL: pmgbackup command failed."
    log_message "Output from pmgbackup:"
    # Add the multi-line output to the log messages for the email
    LOG_MESSAGES+="$BACKUP_OUTPUT"$'\n'
    # Also print it to the console for immediate feedback
    echo "$BACKUP_OUTPUT"
    exit 1
fi

# Extract the backup file path from the success message.
# The output format is: "starting backup to: /path/to/file.tgz"
LATEST_BACKUP_FILE=$(echo "$BACKUP_OUTPUT" | grep -oP 'starting backup to: \K.+')

if [[ -z "$LATEST_BACKUP_FILE" || ! -f "$LATEST_BACKUP_FILE" ]]; then
    SCRIPT_STATUS="FAILURE"
    log_message "FATAL: Could not determine backup file path from pmgbackup output."
    log_message "Output from pmgbackup: $BACKUP_OUTPUT"
    exit 1
fi
log_message "Successfully created backup: $LATEST_BACKUP_FILE"

# Step 2: Rotate local backups
# -----------------------------------------------------------------
log_message "Rotating local backups in $BACKUP_DIR. Keeping last $MAX_BACKUPS."

# List files by modification time (newest first), then select all files *after* the number to keep.
# This is more robust than using 'head'.
FILES_TO_DELETE=$(ls -1t "$BACKUP_DIR"/pmg-backup_*.tgz | tail -n +$(($MAX_BACKUPS + 1)))

if [[ -n "$FILES_TO_DELETE" ]]; then
    log_message "The following old local backups will be deleted:"
    # Print the list of files to the console for immediate feedback.
    echo "$FILES_TO_DELETE"
    # Log the files to be deleted to the email for tracking.
    LOG_MESSAGES+="$FILES_TO_DELETE"$'\n'
    # Pipe the list of files to be removed.
    echo "$FILES_TO_DELETE" | xargs -r rm
    log_message "Old local backups have been deleted."
else
    log_message "No old local backups to delete."
fi

# Step 3 & 4: Sync to remote server and rotate remote backups
# -----------------------------------------------------------------
if [[ "$RSYNC_ENABLED" == "true" ]]; then
    log_message "Rsync to remote server is enabled."
    
    if ! command -v rsync &> /dev/null; then
        SCRIPT_STATUS="FAILURE"
        log_message "FATAL: 'rsync' command not found, but rsync is enabled. Please install rsync."
        exit 1
    fi
    
    log_message "Syncing backup to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}"
    
    # Define separate SSH options for rsync (needs a string) and direct ssh (needs an array).
    SSH_OPTS_FOR_RSYNC=""
    SSH_OPTS_FOR_DIRECT=()

    if [[ -n "$REMOTE_SSH_KEY" && -f "$REMOTE_SSH_KEY" ]]; then
        log_message "Using SSH key for authentication: $REMOTE_SSH_KEY"
        SSH_OPTS_FOR_RSYNC="-e 'ssh -i $REMOTE_SSH_KEY -o StrictHostKeyChecking=no'"
        SSH_OPTS_FOR_DIRECT=("-i" "$REMOTE_SSH_KEY" "-o" "StrictHostKeyChecking=no")
    else
        log_message "WARNING: SSH key not specified or not found. Rsync may prompt for a password if not configured for passwordless login."
    fi

    # The 'eval' is necessary to correctly handle the quoted -e option for rsync.
    if ! eval rsync -av --progress $SSH_OPTS_FOR_RSYNC "$LATEST_BACKUP_FILE" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"; then
        SCRIPT_STATUS="FAILURE"
        log_message "FATAL: Rsync command failed to sync the backup to the remote server."
        exit 1
    fi
    log_message "Rsync completed successfully."

    # Rotate remote backups
    log_message "Rotating remote backups on ${REMOTE_HOST}. Keeping last $REMOTE_MAX_BACKUPS."
    
    # This command is executed on the remote server. It lists backups, sorts them,
    # and pipes the oldest ones to 'rm' for deletion.
    REMOTE_CMD="cd '$REMOTE_DIR' && ls -1t pmg-backup_*.tgz | tail -n +$(($REMOTE_MAX_BACKUPS + 1)) | xargs -r rm"

    log_message "Executing remote rotation command..."
    
    # Use an if/else structure to handle non-fatal errors gracefully with 'set -e'.
    if ssh "${SSH_OPTS_FOR_DIRECT[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "$REMOTE_CMD"; then
        log_message "Remote rotation completed successfully."
    else
        # A failure here is a warning, not a critical failure of the backup itself.
        log_message "WARNING: Remote rotation command failed. The backup was transferred, but old remote files may not have been deleted."
    fi
else
    log_message "Rsync to remote server is disabled. Skipping remote operations."
fi

# The EXIT trap will now run the cleanup function to send the final SUCCESS notification.
exit 0
