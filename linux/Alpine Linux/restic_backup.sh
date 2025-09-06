#!/usr/bin/env bash
# restic_backup.sh
# =================================================================
# Restic Backup Script for Alpine Linux
# Copyright (c) 2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
# =================================================================
# This script automates the backup of specified files, directories,
# and MariaDB databases to a Restic repository (B2 or SFTP).
#
# It performs the following actions:
# 1. Sources credentials from an environment file based on the chosen backup method.
# 2. Performs pre-flight checks for required commands, paths, and DB connectivity.
# 3. Dumps all MariaDB databases to a temporary location.
# 4. Backs up specified paths and the database dumps using Restic.
# 5. Applies a retention policy to prune old snapshots.
# 6. Sends a detailed email notification with the full log upon completion or failure.
# 7. Securely cleans up all temporary files.
#
# Usage:
# 1. Customize the variables in the "User Configuration" section.
# 2. Make the script executable: chmod 700 /path/to/your/script/restic_backup.sh
# 3. Schedule it with cron to run automatically.
# =================================================================

# --- Script Configuration ---
# Exit on error, treat unset variables as an error, and fail on piped command errors.
set -o errexit -o nounset -o pipefail

# =================================================================
# --- User Configuration ---
# Please edit the variables in this section to match your setup.
# =================================================================

# --- Backup Method ---
# Choose your backup method: "B2" or "SFTP"
readonly BACKUP_METHOD="SFTP"

# --- SFTP Specific Configuration ---
# Only used if BACKUP_METHOD is "SFTP"
readonly SFTP_SSH_KEY="/root/.ssh/restic_key" # Path to the SSH private key for SFTP

# --- Email Notifications ---
readonly EMAIL_ENABLED="true"
readonly FROM_ADDRESS="LEMP Backup <backup@your-server.com>"
readonly RECIPIENT_ADDRESS="your-email@example.com"

# --- Database Credentials ---
readonly DB_USER="root"
readonly DB_PASSWORD='strong_root_password'

# --- Paths & Retention ---
# A list of all files and directories to back up.
readonly PATHS_TO_BACKUP=(
    "/home/site1"
    "/home/site2"
    "/etc/nginx"
    "/etc/php83"
    "/etc/php84"
    "/etc/ssh/sshd_config"
    "/etc/nftables.nft"
    "/etc/logrotate.d"
    "/usr/local/bin"
)
# Restic retention policy: How many snapshots to keep.
readonly KEEP_DAILY=7
readonly KEEP_WEEKLY=4
readonly KEEP_MONTHLY=12
readonly KEEP_YEARLY=3

# --- Environment Files ---
# Paths to the files containing your Restic repository credentials.
readonly B2_ENV_FILE="/root/.restic-b2.env"
readonly SFTP_ENV_FILE="/root/.restic-sftp.env"

# =================================================================
# --- Do Not Edit Below This Line ---
# =================================================================

# --- Script Internal Variables ---
readonly BACKUP_DIR="/tmp/backups-$(date +%s)" # Unique temp dir
readonly TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

# --- Global Variables & Functions ---
LOG_BODY=""
SCRIPT_STATUS="SUCCESS"

# Logs a formatted message and adds it to the email body.
log_message() {
    local formatted_message
    formatted_message=$(printf '[%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$1")
    # Print to console with a newline
    echo "${formatted_message}"
    # Add to email body with a newline
    LOG_BODY+="${formatted_message}\n"
}

# Appends raw, multi-line command output to the email body.
log_output() {
    echo "${1}"
    LOG_BODY+="\n--- Command Output ---\n${1}\n--- End Output ---\n"
}

# Sends the final email notification using sendmail.
send_notification() {
    if [[ "${EMAIL_ENABLED}" != "true" ]]; then return; fi
    log_message "Sending email notification to ${RECIPIENT_ADDRESS}..."
    local subject="LEMP Server Backup Status: ${SCRIPT_STATUS} on $(hostname)"
    /usr/sbin/sendmail -t -oi <<EOM
From: ${FROM_ADDRESS}
To: ${RECIPIENT_ADDRESS}
Subject: ${subject}

${LOG_BODY}
EOM
}

# Ensures temporary files are cleaned up securely on any exit.
cleanup() {
    local exit_code=$?
    # The ERR trap will have already set the status to FAILURE.
    if [[ $exit_code -eq 0 && "${SCRIPT_STATUS}" == "SUCCESS" ]]; then
        log_message "--- Backup and prune completed successfully. ---"
    else
        # This message handles cases where a non-trapped error might occur.
        log_message "--- Backup script finished with status: ${SCRIPT_STATUS} (Exit Code: ${exit_code}). ---"
    fi
    
    send_notification
    
    if [ -d "$BACKUP_DIR" ]; then
        log_message "Cleaning up temporary files from ${BACKUP_DIR}..."
        rm -rf "$BACKUP_DIR"
    fi
}

# Sets the failure status when an error is trapped.
handle_error() {
    local line_number=$1
    local command=$2
    SCRIPT_STATUS="FAILURE"
    log_message "ERROR on line ${line_number}: command failed: \`${command}\`"
}

# --- Main Logic ---
main() {
    trap 'handle_error $LINENO "$BASH_COMMAND"' ERR
    trap cleanup EXIT

    log_message "--- Starting LEMP Server Backup using ${BACKUP_METHOD} method ---"

    # --- 1. Pre-flight Checks ---
    log_message "Performing pre-flight checks..."
    local dependencies=("restic" "mariadb" "mariadb-dump" "sendmail" "ssh")
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_message "FATAL: Required command '${cmd}' is not installed or not in PATH."
            exit 1
        fi
    done

    # Source the correct environment file based on BACKUP_METHOD
    local env_file=""
    if [ "$BACKUP_METHOD" == "B2" ]; then
        env_file="${B2_ENV_FILE}"
    elif [ "$BACKUP_METHOD" == "SFTP" ]; then
        env_file="${SFTP_ENV_FILE}"
    else
        log_message "FATAL: Invalid BACKUP_METHOD specified: '${BACKUP_METHOD}'. Must be 'B2' or 'SFTP'."
        exit 1
    fi

    if [[ ! -f "${env_file}" ]]; then
        log_message "FATAL: Environment file not found: ${env_file}"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "${env_file}"
    log_message "Successfully sourced credentials from ${env_file}"

    # Verify that the repository is set
    if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
        log_message "FATAL: RESTIC_REPOSITORY is not set in ${env_file}."
        exit 1
    fi

    # Check for SFTP SSH key and test the connection if that method is selected
    if [[ "$BACKUP_METHOD" == "SFTP" ]]; then
        if [[ ! -r "${SFTP_SSH_KEY}" ]]; then
            log_message "FATAL: SFTP SSH key is not readable at: ${SFTP_SSH_KEY}"
            exit 1
        fi
        log_message "SFTP SSH key check passed."
        
        log_message "Testing SFTP connection to remote server..."
        # Extract user@host from the RESTIC_REPOSITORY string for the test
        local sftp_target
        sftp_target=$(echo "${RESTIC_REPOSITORY}" | sed -E 's|sftp:([^:]+):.*|\1|')
        
        if ! ssh -q -i "${SFTP_SSH_KEY}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${sftp_target}" 'exit'; then
            log_message "FATAL: SFTP connection test failed. Restic will not be able to connect."
            log_message "Please check the following:"
            log_message "1. The SSH key at '${SFTP_SSH_KEY}' has the correct permissions (600)."
            log_message "2. The public key has been added to the authorized_keys file on the remote server."
            log_message "3. The user and host ('${sftp_target}') are correct."
            log_message "4. There are no network issues (firewalls, etc.) blocking the connection."
            exit 1
        fi
        log_message "SFTP connection test successful."
    fi
    
    # Check database connectivity
    if ! mariadb -u"${DB_USER}" -p"${DB_PASSWORD}" -e "SELECT 1;" &>/dev/null; then
        log_message "FATAL: Could not connect to MariaDB. Please check credentials."
        exit 1
    fi
    log_message "Database connection successful."
    
    # --- 2. Create Temporary Backup Directory ---
    mkdir -p "$BACKUP_DIR"
    log_message "Created temporary backup directory at ${BACKUP_DIR}"

    # --- 3. System State & Database Backup ---
    log_message "Backing up system state..."
    apk info > "${BACKUP_DIR}/packages.list"
    rc-update show > "${BACKUP_DIR}/services.list"

    log_message "Dumping all MariaDB databases..."
    # Use a while-read loop for safe handling of database names.
    local db_list
    db_list=$(mariadb -u"${DB_USER}" -p"${DB_PASSWORD}" -sN -e "SHOW DATABASES;" | grep -Ev "(information_schema|performance_schema|mysql)")
    
    echo "${db_list}" | while IFS= read -r db; do
        if [[ -n "$db" ]]; then
            log_message "  - Dumping database: ${db}"
            mariadb-dump --user="${DB_USER}" --password="${DB_PASSWORD}" --databases "$db" > "${BACKUP_DIR}/${db}.sql"
        fi
    done

    # --- 4. Restic Backup ---
    log_message "Starting Restic backup to ${RESTIC_REPOSITORY}..."
    
    # If using SFTP, set the command via an environment variable.
    # This is more robust than using the -o flag and avoids parsing issues.
    if [[ "$BACKUP_METHOD" == "SFTP" ]]; then
        export RESTIC_SFTP_COMMAND="ssh -q -i ${SFTP_SSH_KEY} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
    fi

    local backup_output
    # The RESTIC_SFTP_COMMAND env var is automatically picked up by restic.
    backup_output=$(restic backup \
        --tag automated \
        --tag "${BACKUP_METHOD}" \
        --files-from <(printf "%s\n" "${PATHS_TO_BACKUP[@]}") \
        "${BACKUP_DIR}")
    log_output "${backup_output}"

    # --- 5. Restic Pruning ---
    log_message "Pruning old snapshots according to retention policy..."
    local forget_output
    # The environment variable will also be used by this command.
    forget_output=$(restic forget \
        --keep-daily ${KEEP_DAILY} \
        --keep-weekly ${KEEP_WEEKLY} \
        --keep-monthly ${KEEP_MONTHLY} \
        --keep-yearly ${KEEP_YEARLY} \
        --prune)
    log_output "${forget_output}"
}

# Execute the main function.
main
