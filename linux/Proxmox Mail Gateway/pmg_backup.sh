#!/usr/bin/env bash
# pmg_backup.sh
# =================================================================
# Proxmox Mail Gateway Backup Script with Rotation and Rsync
# Copyright (c) 2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
# =================================================================
# This script performs the following actions:
# 1. Creates a backup of the PMG configuration using pmgbackup.
# 2. Rotates local backups, keeping a specified number of recent backups.
# 3. (Optional) Syncs the latest backup to a remote server via rsync over SSH.
# 4. (Optional) Rotates backups on the remote server.
# 5. Sends a detailed email notification upon success or failure.
#
# Usage:
# 1. Customize the variables in the "User-defined Variables" section.
# 2. Make the script executable: chmod +x /path/to/your/script/pmg_backup.sh
# 3. Schedule it with cron: crontab -e
#    Add a line like: 0 2 * * * /path/to/your/script/pmg_backup.sh
# =================================================================

# --- Script Configuration ---
# Exit on error, treat unset variables as an error, and fail on piped command errors.
set -o errexit -o nounset -o pipefail

# --- User-defined Variables ---

# Local Backup Configuration
readonly MAX_BACKUPS=5
readonly BACKUP_DIR="/var/lib/pmg/backup"

# Remote Server rsync Configuration
readonly RSYNC_ENABLED="true"
readonly REMOTE_HOST="your.server.com"
readonly REMOTE_USER="backup"
readonly REMOTE_DIR="/path/to/remote/backups"
readonly REMOTE_SSH_KEY="/root/.ssh/id_ed25519"
readonly REMOTE_MAX_BACKUPS=90

# Email Notification Configuration
readonly EMAIL_ENABLED="true"
readonly FROM_ADDRESS="PMG Backup <noreply@example.com>"
readonly RECIPIENT_ADDRESS="admin@example.com"

# --- Global Variables ---
LOG_BODY=""
SCRIPT_STATUS="SUCCESS"

# --- Functions ---

# Logs a message to the console and appends it to the email body.
log_message() {
    # Use printf for more reliable output formatting.
    local message
    message=$(printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1")
    echo "$message"
    LOG_BODY+="${message}"
}

# Appends raw command output to the log body for inclusion in emails.
log_output() {
    LOG_BODY+="$1"$'\n'
}

# Sends the final email notification using the 'mail' command.
send_notification() {
    if [[ "${EMAIL_ENABLED}" != "true" ]]; then
        return
    fi
    log_message "Sending email notification to ${RECIPIENT_ADDRESS}..."
    local subject="PMG Backup Status: ${SCRIPT_STATUS} on $(hostname)"

    # Use a here-string for cleaner piping to the 'mail' command.
    mail -s "${subject}" -a "From: ${FROM_ADDRESS}" "${RECIPIENT_ADDRESS}" <<< "${LOG_BODY}"
}

# Handles script exit, logging the final status and sending a notification.
# This function is triggered by the EXIT signal.
cleanup() {
    # The final status will already be set to FAILURE by the ERR trap if an error occurred.
    if [[ "${SCRIPT_STATUS}" == "SUCCESS" ]]; then
        log_message "Backup process finished successfully."
    else
        log_message "Backup process finished with a FAILURE status."
    fi
    send_notification
}

# Handles errors by logging the failed command and line number.
# This function is triggered by the ERR signal.
handle_error() {
    local line_number=$1
    local command=$2
    SCRIPT_STATUS="FAILURE"
    log_message "ERROR on line ${line_number}: command failed: \`${command}\`"
    log_message "Aborting script due to critical error."
}

# --- Main Script Logic ---
main() {
    # Register trap functions to handle script exit and errors.
    trap 'handle_error $LINENO "$BASH_COMMAND"' ERR
    trap cleanup EXIT

    log_message "Starting Proxmox Mail Gateway backup process..."

    # --- Pre-flight Checks ---
    if [[ "${EMAIL_ENABLED}" == "true" ]] && ! command -v mail &>/dev/null; then
        log_message "FATAL: 'mail' command not found, but email is enabled. Please install mailutils or equivalent."
        exit 1
    fi
    if [[ "${RSYNC_ENABLED}" == "true" ]] && ! command -v rsync &>/dev/null; then
        log_message "FATAL: 'rsync' not found, but rsync is enabled. Please install rsync."
        exit 1
    fi

    # --- 1. Create Local Backup ---
    log_message "Creating local PMG backup..."
    local backup_output
    backup_output=$(pmgbackup backup)
    log_output "${backup_output}"

    # Use awk for portable and robust parsing of the backup file path.
    local latest_backup_file
    latest_backup_file=$(echo "${backup_output}" | awk -F': ' '/starting backup to:/ {print $2}')

    if [[ -z "${latest_backup_file}" || ! -f "${latest_backup_file}" ]]; then
        log_message "FATAL: Could not determine backup file path or file does not exist."
        exit 1
    fi
    log_message "Successfully created backup: ${latest_backup_file}"

    # --- 2. Rotate Local Backups ---
    log_message "Rotating local backups in ${BACKUP_DIR}. Keeping last ${MAX_BACKUPS}."
    # Use find for safer file handling than parsing ls output.
    local files_to_delete
    files_to_delete=$(find "${BACKUP_DIR}" -maxdepth 1 -type f -name "pmg-backup_*.tgz" -printf "%T@ %p\n" | sort -nr | tail -n +$((MAX_BACKUPS + 1)) | cut -d' ' -f2-)

    if [[ -n "${files_to_delete}" ]]; then
        log_message "The following old local backups will be deleted:"
        # Also print the files to be deleted to the console for immediate feedback.
        echo "${files_to_delete}"
        log_output "${files_to_delete}"
        echo "${files_to_delete}" | xargs -r rm
        log_message "Old local backups have been deleted."
    else
        log_message "No old local backups to delete."
    fi

    # --- 3. Sync to Remote Server ---
    if [[ "${RSYNC_ENABLED}" != "true" ]]; then
        log_message "Rsync to remote server is disabled. Skipping."
        return
    fi
    
    log_message "Syncing backup to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}"
    
    # Build command arrays to avoid using `eval`, which is safer.
    local rsync_opts=(-av --progress)
    local ssh_opts=()

    if [[ -n "${REMOTE_SSH_KEY}" && -f "${REMOTE_SSH_KEY}" ]]; then
        log_message "Using SSH key for authentication: ${REMOTE_SSH_KEY}"
        rsync_opts+=(-e "ssh -i ${REMOTE_SSH_KEY} -o StrictHostKeyChecking=no")
        ssh_opts+=(-i "${REMOTE_SSH_KEY}" -o StrictHostKeyChecking=no)
    else
        log_message "WARNING: SSH key not specified or not found. Rsync may prompt for a password."
    fi

    # Treat remote sync as non-critical. If it fails, log a warning but don't terminate the script.
    if rsync "${rsync_opts[@]}" "${latest_backup_file}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"; then
        log_message "Rsync completed successfully."

        # --- 4. Rotate Remote Backups (Only run if rsync was successful) ---
        log_message "Rotating remote backups on ${REMOTE_HOST}. Keeping last ${REMOTE_MAX_BACKUPS}."
        
        # This command is executed on the remote server.
        local remote_cmd="cd '${REMOTE_DIR}' && ls -1t pmg-backup_*.tgz | tail -n +$((${REMOTE_MAX_BACKUPS} + 1)) | xargs -r rm"
        
        log_message "Executing remote rotation command..."
        # A failure here is also treated as a warning.
        if ! ssh "${ssh_opts[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "${remote_cmd}"; then
            log_message "WARNING: Remote rotation command failed. The backup was transferred, but old remote files may not have been deleted."
        else
            log_message "Remote rotation completed successfully."
        fi
    else
        log_message "WARNING: Rsync failed to sync the backup to the remote server. The local backup is safe, but the remote copy is not up-to-date."
        # Do not set SCRIPT_STATUS to FAILURE. The warning in the log is sufficient.
    fi
}

# Execute the main function.
main
