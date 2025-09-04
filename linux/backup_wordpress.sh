#!/usr/bin/env bash
# backup_wordpress.sh
# =================================================================
# WordPress Backup Script with Auto-Dependency Check & Rotation
# Copyright (c) 2024-2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
# =================================================================
# This script automates WordPress backups with robust error handling and logging.
# - Detects the OS and offers to install missing dependencies (zstd, rsync, etc.).
# - Creates compressed backups of the database and website files using Zstandard.
# - Rotates backups locally and on a remote server to save space.
# - Syncs backups to a remote server using rsync over SSH.
# - Sends detailed email notifications for backup success or failure.
# - Includes pre-flight checks for required commands, permissions, and file sizes.
#
# Crontab example to run daily at 1:00 AM:
# 0 1 * * * /path/to/your/script/backup_wordpress.sh
# =================================================================

# --- Script Configuration ---
# Exit on error, treat unset variables as an error, and fail on piped command errors.
set -o errexit -o nounset -o pipefail

# --- User-defined Variables ---

# Site Configuration
readonly SITE_NAME="example.com"
readonly SITE_ROOT="/var/www/html"

# Backup Configuration
readonly BACKUP_DIR="/home/user/backups"
readonly MAX_BACKUPS=7
readonly MIN_DB_BACKUP_SIZE=102400 # Min DB backup size in bytes (e.g., 100KB)

# Remote Server rsync Configuration
readonly RSYNC_ENABLED="true"
readonly REMOTE_HOST="remote-backup-server.local"
readonly REMOTE_USER="backupuser"
readonly REMOTE_DIR="/mnt/backups/websites"
readonly REMOTE_SSH_KEY="/home/user/.ssh/id_rsa"
readonly REMOTE_MAX_BACKUPS=30

# Email Notification Configuration
readonly EMAIL_ENABLED="true"
readonly FROM_ADDRESS="WordPress Backup <wordpress-backup@example.com>"
readonly RECIPIENT_ADDRESS="admin@example.com"

# --- Global Variables ---
LOG_BODY=""
SCRIPT_STATUS="SUCCESS"
readonly LOG_FILE="${BACKUP_DIR}/${SITE_NAME}-wp-backup.log"

# --- Functions ---

# Logs a message to the console, appends it to the log file, and adds it to the email body.
log_message() {
    local message
    message=$(printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1")
    # Use 'echo' instead of 'echo -n' to ensure newlines are printed.
    echo "${message}" | tee -a "${LOG_FILE}"
    LOG_BODY+="${message}"
}

# Sends the final email notification using sendmail for reliability.
send_notification() {
    if [[ "${EMAIL_ENABLED}" != "true" ]]; then
        return
    fi
    log_message "Sending email notification to ${RECIPIENT_ADDRESS}..."
    local subject="WordPress Backup Status: ${SCRIPT_STATUS} on $(hostname) for ${SITE_NAME}"

    /usr/sbin/sendmail -t -oi <<EOF
From: ${FROM_ADDRESS}
To: ${RECIPIENT_ADDRESS}
Subject: ${subject}

${LOG_BODY}
EOF
}

# Handles script exit, logging the final status and sending a notification.
cleanup() {
    if [[ "${SCRIPT_STATUS}" == "SUCCESS" ]]; then
        log_message "--- WordPress Backup for ${SITE_NAME} Completed Successfully! ---"
    else
        log_message "--- Backup script finished with a FAILURE status. ---"
    fi
    send_notification
}

# Handles errors by logging the failed command and line number.
handle_error() {
    local line_number=$1
    local command=$2
    SCRIPT_STATUS="FAILURE"
    log_message "ERROR on line ${line_number}: command failed: \`${command}\`"
    log_message "Aborting script due to critical error."
}

# Detects the OS and offers to install missing packages.
check_and_install_dependencies() {
    log_message "Checking for required dependencies..."
    local missing_packages=()
    local os_id=""
    local pkg_manager=""
    local install_cmd=""

    if [[ -f /etc/os-release ]]; then
        # Use awk for better portability than grep -P, especially on BusyBox systems like Alpine.
        os_id=$(awk -F= '$1=="ID" { gsub(/"/, ""); print $2 }' /etc/os-release)
    fi

    case "$os_id" in
        alpine)
            pkg_manager="apk"
            install_cmd="sudo apk add"
            ;;
        debian|ubuntu)
            pkg_manager="apt"
            install_cmd="sudo apt-get install -y"
            ;;
        centos|rhel|rocky|almalinux)
            pkg_manager="yum/dnf"
            install_cmd="sudo yum install -y"
            if command -v dnf &>/dev/null; then
                install_cmd="sudo dnf install -y"
            fi
            ;;
        *)
            log_message "WARNING: Unsupported OS detected. Cannot auto-install dependencies."
            return
            ;;
    esac

    local dependencies=( "mysqldump:mariadb-client" "zstd:zstd" "tar:tar" "rsync:rsync" "sendmail:sendmail" "ssh:openssh-client" )
    if [[ "$os_id" == "centos" || "$os_id" == "rhel" || "$os_id" == "rocky" || "$os_id" == "almalinux" ]]; then
        dependencies=( "mysqldump:mariadb" "zstd:zstd" "tar:tar" "rsync:rsync" "sendmail:postfix" "ssh:openssh-clients" )
    elif [[ "$os_id" == "alpine" ]]; then
        dependencies=( "mysqldump:mariadb-client" "zstd:zstd" "tar:tar" "rsync:rsync" "sendmail:ssmtp" "ssh:openssh-client" ) # ssmtp provides sendmail
    fi
    
    for item in "${dependencies[@]}"; do
        IFS=":" read -r cmd pkg <<< "$item"
        if ! command -v "$cmd" &> /dev/null && ! command -v "mariadb-dump" &> /dev/null; then
             missing_packages+=("$pkg")
        fi
    done

    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        log_message "The following required packages are missing: ${missing_packages[*]}"
        read -p "Would you like to attempt to install them now? (y/n): " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            if ! command -v sudo &>/dev/null; then
                log_message "FATAL: 'sudo' is required to install packages. Please install it or run this script as root."
                exit 1
            fi
            log_message "Installing packages with ${pkg_manager}..."
            ${install_cmd} "${missing_packages[@]}"
        else
            log_message "FATAL: Installation declined. The script cannot continue without required dependencies."
            exit 1
        fi
    fi
    log_message "All required dependencies are satisfied."
}

# --- Main Script Logic ---
main() {
    trap 'handle_error $LINENO "$BASH_COMMAND"' ERR
    trap cleanup EXIT
    
    mkdir -p "${BACKUP_DIR}"
    
    log_message "--- Starting WordPress Backup for ${SITE_NAME} ---"
    
    check_and_install_dependencies

    # --- Pre-flight Checks ---
    log_message "Performing remaining pre-flight checks..."
    [[ -d "${SITE_ROOT}" ]] || { log_message "FATAL: WordPress root directory does not exist: ${SITE_ROOT}"; exit 1; }
    [[ -w "${BACKUP_DIR}" ]] || { log_message "FATAL: Backup directory is not writable: ${BACKUP_DIR}"; exit 1; }
    [[ -f "${SITE_ROOT}/wp-config.php" ]] || { log_message "FATAL: Could not find wp-config.php in ${SITE_ROOT}"; exit 1; }
    if [[ "${RSYNC_ENABLED}" == "true" && ! -r "${REMOTE_SSH_KEY}" ]]; then
        log_message "FATAL: SSH key is not readable: ${REMOTE_SSH_KEY}"
        exit 1
    fi
    log_message "Pre-flight checks passed."

    # --- Rotate Local Backups ---
    log_message "Rotating local backups... keeping last ${MAX_BACKUPS} sets."
    # Use a portable method to find and rotate backups that works with BusyBox find/sed.
    local old_dates
    old_dates=$(find "${BACKUP_DIR}" -maxdepth 1 -type f -name "${SITE_NAME}-wp_*" | \
        sed 's/.*-\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)\..*/\1/' | \
        sort -ur | tail -n +$((MAX_BACKUPS + 1)))
        
    if [[ -n "$old_dates" ]]; then
        for date in $old_dates; do
            log_message "Deleting old backup set from ${date}..."
            find "${BACKUP_DIR}" -maxdepth 1 -type f -name "*${date}*" -print | tee -a "${LOG_FILE}" | xargs -r rm
        done
    else
        log_message "No old local backup sets to rotate."
    fi

    # --- Extract DB Credentials ---
    log_message "Extracting database credentials from wp-config.php..."
    local DB_NAME DB_USER DB_PASSWORD DB_HOST
    DB_NAME=$(grep "DB_NAME" "${SITE_ROOT}/wp-config.php" | cut -d "'" -f 4)
    DB_USER=$(grep "DB_USER" "${SITE_ROOT}/wp-config.php" | cut -d "'" -f 4)
    DB_PASSWORD=$(grep "DB_PASSWORD" "${SITE_ROOT}/wp-config.php" | cut -d "'" -f 4)
    DB_HOST=$(grep "DB_HOST" "${SITE_ROOT}/wp-config.php" | cut -d "'" -f 4)
    log_message "Successfully extracted database credentials."

    # --- Determine Dump Command ---
    local DUMP_COMMAND="mysqldump"
    if command -v mariadb-dump &> /dev/null; then
        DUMP_COMMAND="mariadb-dump"
    fi

    # --- Create Backups ---
    local DATE_STAMP
    DATE_STAMP=$(date +%Y-%m-%d)
    local DB_BACKUP_FILE="${BACKUP_DIR}/${SITE_NAME}-wp_db-${DATE_STAMP}.sql.zst"
    local FILES_BACKUP_FILE="${BACKUP_DIR}/${SITE_NAME}-wp_files-${DATE_STAMP}.tar.zst"

    log_message "Starting database backup for '${DB_NAME}' using '${DUMP_COMMAND}'..."
    "${DUMP_COMMAND}" -u"${DB_USER}" -p"${DB_PASSWORD}" -h"${DB_HOST}" "${DB_NAME}" | zstd -T0 > "${DB_BACKUP_FILE}"
    log_message "Database backup created: ${DB_BACKUP_FILE}"
    
    local db_backup_size
    db_backup_size=$(stat -c%s "${DB_BACKUP_FILE}")
    if (( db_backup_size < MIN_DB_BACKUP_SIZE )); then
        log_message "FATAL: DB backup size (${db_backup_size} bytes) is below minimum (${MIN_DB_BACKUP_SIZE} bytes)."
        exit 1
    fi
    log_message "Database backup size is acceptable."

    log_message "Starting website files backup from '${SITE_ROOT}'..."
    tar -cf - -C "${SITE_ROOT}" . | zstd -T0 > "${FILES_BACKUP_FILE}"
    log_message "Website files backup created: ${FILES_BACKUP_FILE}"

    # --- Sync to Remote Server ---
    if [[ "${RSYNC_ENABLED}" != "true" ]]; then
        log_message "Rsync is disabled. Skipping remote operations."
    else
        log_message "Syncing backups to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}"
        local ssh_opts=(-i "${REMOTE_SSH_KEY}" -o StrictHostKeyChecking=accept-new)
        local rsync_opts=(-avz -e "ssh ${ssh_opts[*]}")
        
        ssh "${ssh_opts[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p '${REMOTE_DIR}'"
        rsync "${rsync_opts[@]}" "${DB_BACKUP_FILE}" "${FILES_BACKUP_FILE}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"
        log_message "Rsync to remote server completed."
        
        log_message "Rotating remote backups... keeping last ${REMOTE_MAX_BACKUPS} sets."
        # Use a more robust, multi-line command for remote rotation to avoid segmentation faults on BusyBox.
        local remote_cmd="
cd '${REMOTE_DIR}' || exit 1
OLD_DATES=\$(find . -maxdepth 1 -type f -name '${SITE_NAME}-wp_*' | sed 's/.*-\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)\..*/\1/' | sort -ur | tail -n +$((REMOTE_MAX_BACKUPS + 1)))
if [ -n \"\$OLD_DATES\" ]; then
    for date in \$OLD_DATES; do
        echo \"Deleting remote backup set from \${date}...\"
        find . -maxdepth 1 -name \"*_\${date}.*\" -print -delete
    done
else
    echo \"No old remote backups to delete.\"
fi"
        if ! ssh "${ssh_opts[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "${remote_cmd}"; then
            log_message "WARNING: Failed to rotate remote backups. This is a non-critical error."
        else
            log_message "Remote backup rotation complete."
        fi
    fi
}

main "$@"

