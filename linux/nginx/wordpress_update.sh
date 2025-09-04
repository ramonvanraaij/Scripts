#!/usr/bin/env bash
# wordpress_update.sh
# =================================================================
# WordPress Update and Maintenance Script with Logging and Email
# Copyright (c) 2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# =================================================================
# This script performs the following actions:
# 1. Enables maintenance mode in WordPress to prevent user interruptions.
# 2. Updates WP-CLI, WordPress core, themes, and plugins.
# 3. Flushes the WordPress object cache.
# 4. (Optional) Clears the Nginx fastcgi cache and restarts Nginx.
# 5. Disables maintenance mode.
# 6. (Optional) Executes a user-defined post-update script.
# 7. Sends a detailed email notification upon completion or failure using sendmail.
#
# Usage:
# 1. Customize the variables in the "User-defined Variables" section below.
# 2. Make the script executable: chmod +x /path/to/your/script/wordpress_update.sh
# 3. Schedule it with cron for automated execution: crontab -e
#    # Example: Run every Saturday at 3:00 AM
#    0 3 * * 6 /path/to/your/script/wordpress_update.sh
# =================================================================

# --- User-defined Variables ---
# Use consistent quoting for all variable assignments.
readonly WP_USER="www-data"
readonly WP_PATH="/var/www/html/mysite"
readonly NGINX_CACHE_PATH="/var/cache/nginx/site"
readonly CLEAR_NGINX_CACHE="true"

# Update Configuration
readonly UPDATE_THEMES="true"
readonly UPDATE_PLUGINS="true"
readonly UPDATE_CORE="true"

# Email Notification Configuration
readonly EMAIL_ENABLED="true"
readonly FROM_ADDRESS="WordPress Update <wordpress-update@example.com>" # Recommended format for From header
readonly RECIPIENT_ADDRESS="admin@example.com"

# --- Script Configuration ---
# Exit on error, treat unset variables as an error, and fail on piped command errors.
set -o errexit -o nounset -o pipefail

# --- Global Variables ---
LOG_BODY=""
SCRIPT_STATUS="SUCCESS"
# Use parameter expansion to safely handle an empty argument for the optional script.
readonly OPTIONAL_SCRIPT="${1:-}"

# --- Functions ---

# Logs a message to the console and appends it to the email body.
log_message() {
    # Use printf for more reliable output formatting and quoting.
    local message
    message=$(printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1")
    echo "$message"
    LOG_BODY+="${message}"$'\n'
}

# Sends the final email notification using sendmail.
send_notification() {
    if [[ "$EMAIL_ENABLED" != "true" ]]; then
        return
    fi

    log_message "Sending email notification to ${RECIPIENT_ADDRESS}..."
    local subject="WordPress Update Status: ${SCRIPT_STATUS} on $(hostname)"

    # Construct email with headers for sendmail using a "here document".
    # This is a more reliable method than piping.
    /usr/sbin/sendmail -t -oi <<EOF
From: ${FROM_ADDRESS}
To: ${RECIPIENT_ADDRESS}
Subject: ${subject}

${LOG_BODY}
EOF
}

# Ensures maintenance mode is disabled, logs final status, and sends a notification.
# This function is triggered by the EXIT signal.
cleanup() {
    local exit_code=$? # Capture the exit code of the last command.

    # Deactivate maintenance mode if it's still active, which can happen on script failure.
    # This prevents the site from being stuck in maintenance.
    if sudo -u "$WP_USER" -- wp maintenance-mode is-active --path="$WP_PATH" &>/dev/null; then
        log_message "Attempting to disable maintenance mode before exiting..."
        sudo -u "$WP_USER" -- wp maintenance-mode deactivate --path="$WP_PATH" || log_message "WARNING: Failed to disable maintenance mode automatically."
    fi

    if [[ $exit_code -ne 0 ]]; then
        # This will be triggered by the ERR trap for critical failures.
        log_message "WordPress maintenance script finished with a CRITICAL error."
    elif [[ "$SCRIPT_STATUS" == "SUCCESS_WITH_WARNINGS" ]]; then
        log_message "WordPress maintenance script finished with non-critical warnings. Please review the log."
    elif [[ "$SCRIPT_STATUS" == "SUCCESS" ]]; then
        log_message "WordPress maintenance script finished successfully."
    fi
    send_notification
    exit "$exit_code"
}

# Handles critical errors by logging the failed command and line number.
# This function is triggered by the ERR signal for any command that fails (due to set -o errexit).
handle_error() {
    local line_number=$1
    local command=$2
    SCRIPT_STATUS="FAILURE"
    log_message "ERROR on line ${line_number}: command failed: \`${command}\`"
    log_message "Aborting script due to critical error."
}

# A wrapper for CRITICAL WP-CLI commands that MUST succeed.
# The script will exit if these commands fail.
run_as_wp_user() {
    log_message "Running CRITICAL WP-CLI command: wp $*"
    local raw_output
    # Capture raw output, which may include color codes.
    raw_output=$(sudo -u "$WP_USER" -- wp "$@" --path="$WP_PATH")
    
    if [[ -n "$raw_output" ]]; then
        # Echo the raw output to the terminal to preserve colors.
        echo "$raw_output"
        # Strip ANSI color codes using sed before appending to the email log.
        local clean_output
        clean_output=$(echo "$raw_output" | sed 's/\x1b\[[0-9;]*m//g')
        LOG_BODY+="${clean_output}"$'\n\n'
    fi
}

# A wrapper for NON-CRITICAL WP-CLI commands (e.g., theme/plugin updates).
# Logs warnings on failure but allows the script to continue.
run_update_command() {
    log_message "Running NON-CRITICAL WP-CLI command: wp $*"
    local raw_output
    # Temporarily disable 'exit on error' to handle the potential failure manually.
    set +o errexit
    # Capture raw output (stdout and stderr), which may include color codes.
    raw_output=$(sudo -u "$WP_USER" -- wp "$@" --path="$WP_PATH" 2>&1)
    local exit_code=$?
    set -o errexit # Re-enable 'exit on error'.

    if [[ -n "$raw_output" ]]; then
        # Echo the raw output to the terminal to preserve colors.
        echo "$raw_output"
        # Strip ANSI color codes using sed before appending to the email log.
        local clean_output
        clean_output=$(echo "$raw_output" | sed 's/\x1b\[[0-9;]*m//g')
        LOG_BODY+="${clean_output}"$'\n\n'
    fi

    if [[ $exit_code -ne 0 ]]; then
        log_message "WARNING: Command 'wp $*' finished with a non-zero exit code (${exit_code}). The script will continue."
        if [[ "$SCRIPT_STATUS" == "SUCCESS" ]]; then
            SCRIPT_STATUS="SUCCESS_WITH_WARNINGS"
        fi
    fi
}

# --- Main Script Logic ---
main() {
    # Register trap functions to handle script exit and errors.
    trap 'handle_error $LINENO "$BASH_COMMAND"' ERR
    trap cleanup EXIT

    # --- 1. Pre-flight Checks ---
    log_message "Starting WordPress maintenance script..."

    if [[ $EUID -ne 0 ]]; then
       log_message "FATAL: This script must be run as root." >&2
       exit 1
    fi

    if ! command -v wp &> /dev/null; then
        log_message "FATAL: WP-CLI ('wp') command not found. Please install it." >&2
        exit 1
    fi

    if [[ "$EMAIL_ENABLED" == "true" ]] && ! command -v /usr/sbin/sendmail &> /dev/null; then
        log_message "FATAL: '/usr/sbin/sendmail' command not found, but email notifications are enabled." >&2
        exit 1
    fi

    if [[ ! -d "$WP_PATH" ]]; then
        log_message "FATAL: WordPress path '${WP_PATH}' does not exist." >&2
        exit 1
    fi

    # --- 2. Maintenance and Updates ---
    run_as_wp_user maintenance-mode activate

    log_message "Updating WP-CLI..."
    # WP-CLI update should be run as root. This is a critical command.
    wp cli update --yes --quiet

    if [[ "$UPDATE_CORE" == "true" ]]; then
        # Core updates are critical.
        run_as_wp_user core update
    fi

    if [[ "$UPDATE_PLUGINS" == "true" ]]; then
        # Plugin updates are non-critical.
        run_update_command plugin update --all
    fi

    if [[ "$UPDATE_THEMES" == "true" ]]; then
        # Theme updates are non-critical.
        run_update_command theme update --all
    fi

    # Cache flush is non-critical (it can fail if no object cache is active).
    run_update_command cache flush

    run_as_wp_user maintenance-mode deactivate

    # --- 3. Server-level Tasks ---
    if [[ "$CLEAR_NGINX_CACHE" == "true" ]]; then
        if [[ -d "$NGINX_CACHE_PATH" ]]; then
            log_message "Clearing Nginx cache at ${NGINX_CACHE_PATH}..."
            find "${NGINX_CACHE_PATH}" -type f -delete
            log_message "Restarting Nginx service..."
            # Check for systemctl (newer systems) first, then fall back to service (older systems).
            if command -v systemctl &> /dev/null; then
                systemctl restart nginx
            elif command -v service &> /dev/null; then
                service nginx restart
            else
                log_message "WARNING: Could not find 'systemctl' or 'service' to restart Nginx."
            fi
        else
            log_message "WARNING: NGINX_CACHE_PATH '${NGINX_CACHE_PATH}' does not exist. Skipping cache clear."
        fi
    else
        log_message "Skipping Nginx cache clear as it is disabled."
    fi

    # --- 4. Execute Optional Script ---
    if [[ -n "$OPTIONAL_SCRIPT" ]]; then
        if [[ -f "$OPTIONAL_SCRIPT" && -x "$OPTIONAL_SCRIPT" ]]; then
            log_message "Executing optional script: ${OPTIONAL_SCRIPT}"
            "$OPTIONAL_SCRIPT" || log_message "WARNING: Optional script failed with a non-zero exit code."
        else
            log_message "WARNING: Optional script '${OPTIONAL_SCRIPT}' is not found or not executable. Skipping."
        fi
    fi
}

# Execute the main function, passing all script arguments to it.
main "$@"

