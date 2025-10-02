#!/usr/bin/env bash
# update-proxmox-cloudflare-ips.sh
# =================================================================
# Proxmox Firewall Cloudflare IPSet Updater
#
# Copyright (c) 2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script automates the update of a Proxmox Firewall IPSet with
# the latest Cloudflare IP ranges. It is designed to be run directly
# on a Proxmox VE 9 (or newer) host, which is based on Debian 13 "Trixie".
#
# Featured in the following blog post: https://ramon.vanraaij.eu/the-crowd-sourced-shield-intrusion-prevention-system-web-application-firewall/
#
# It performs the following actions:
# 1. Fetches the latest IPv4 and IPv6 address ranges from Cloudflare.
# 2. Compares the fetched list with the IPs currently in the IPSet.
# 3. If changes are detected, it performs a differential update:
#    a. Adds only the new IP addresses.
#    b. Removes only the stale IP addresses.
#
# --- Setup ---
# 1. Dependencies: This script requires `jq`. You can install it on
#    your Proxmox VE host with:
#    apt update && apt install jq
#
# 2. Configuration: Edit the `IP_SET_NAME` variable below to your desired
#    IPSet name.
#
# 3. Placement: Place this script in a system-wide location, for example:
#    /usr/local/bin/update-proxmox-cloudflare-ips.sh
#
# 4. Permissions: Make the script executable.
#    sudo chmod +x /usr/local/bin/update-proxmox-cloudflare-ips.sh
#
# 5. Automation: The recommended way to automate this script is to create
#    a symbolic link to it in the `/etc/cron.daily` directory. This will
#    cause it to be run once per day.
#    sudo ln -s /usr/local/bin/update-proxmox-cloudflare-ips.sh /etc/cron.daily/update-proxmox-cloudflare-ips
#
# --- Usage ---
# The script is designed for automated execution. You can run it manually
# at any time to force an immediate update (must be run as root):
#   sudo /usr/local/bin/update-proxmox-cloudflare-ips.sh
# =================================================================

# --- Script Configuration ---
# Exit on error, treat unset variables as an error, and fail on piped command errors.
set -o errexit -o nounset -o pipefail

# =================================================================
# --- User Configuration ---
# Please edit the variables in this section to match your setup.
# =================================================================

# The name of the Proxmox Firewall IPSet to manage.
readonly IP_SET_NAME="cloudflare_ips"

# Set to "true" to enable verbose output from pvesh commands for debugging.
readonly DEBUG="true"

# =================================================================
# --- Do Not Edit Below This Line ---
# =================================================================

# --- Script Internal Variables ---
# A temporary name is used for staging the new IP list.
readonly TEMP_IP_SET_NAME="${IP_SET_NAME}_temp"

# --- Functions ---

# Logs a message to the console with a timestamp.
log_message() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

# Wrapper function to run pvesh commands that modify data. It respects the DEBUG flag.
run_pvesh_modify() {
    if [[ "${DEBUG}" == "true" ]]; then
        log_message "DEBUG: Running pvesh $*"
        # In debug mode, run the command and show all output.
        pvesh "$@"
    else
        # In normal mode, hide standard output but allow standard error to pass through.
        pvesh "$@" >/dev/null
    fi
}

# Safely deletes an IPSet by first emptying it.
force_delete_ipset() {
    local set_name="$1"
    # Check if the set exists before trying to clean it up.
    if pvesh get "/cluster/firewall/ipset/${set_name}" >/dev/null 2>&1; then
        log_message "Found IPSet '${set_name}'. Emptying it before deletion..."

        local cidrs_to_delete
        cidrs_to_delete=$(pvesh get "/cluster/firewall/ipset/${set_name}/" --output-format json | jq -r '.[].cidr')
        local ip_count=0

        if [[ -n "$cidrs_to_delete" ]]; then
            # Use a for loop to avoid subshell issues with variable scope.
            for cidr in $cidrs_to_delete; do
                run_pvesh_modify delete "/cluster/firewall/ipset/${set_name}/${cidr}"
                ip_count=$((ip_count + 1))
            done
            log_message "Removed ${ip_count} IPs from '${set_name}'."
        fi

        run_pvesh_modify delete "/cluster/firewall/ipset/${set_name}"
        log_message "Successfully deleted empty IPSet '${set_name}'."
    fi
}

# Ensures the temporary IPSet is always deleted when the script exits.
cleanup() {
    force_delete_ipset "${TEMP_IP_SET_NAME}"
}

# Handles errors by logging the failed command and line number.
handle_error() {
    local line_number=$1
    local command=$2
    log_message "ERROR on line ${line_number}: command failed: \`${command}\`"
    log_message "Aborting due to critical error."
}

# --- Main script logic ---
main() {
    trap 'handle_error $LINENO "$BASH_COMMAND"' ERR
    trap cleanup EXIT

    log_message "--- Starting Proxmox Cloudflare IPSet update ---"

    # --- 1. Pre-flight Checks ---
    if [ "$(id -u)" -ne 0 ]; then
       log_message "FATAL: This script must be run as root." >&2
       exit 1
    fi

    local dependencies="pvesh curl jq comm"
    for cmd in $dependencies; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_message "FATAL: Required command '${cmd}' is not installed or not in PATH." >&2
            exit 1
        fi
    done
    log_message "All required commands are present."

    # --- 2. Fetch Cloudflare IPs ---
    log_message "Fetching latest Cloudflare IP ranges..."
    local all_cf_ips
    all_cf_ips=$(curl -s --fail https://www.cloudflare.com/ips-v4 && echo && curl -s --fail https://www.cloudflare.com/ips-v6)

    if [ -z "$all_cf_ips" ]; then
        log_message "ERROR: Failed to fetch IP ranges from Cloudflare or the result was empty." >&2
        exit 1
    fi
    log_message "Successfully fetched IP ranges."

    # --- 3. Stage New IPs in a Temporary IPSet ---
    force_delete_ipset "${TEMP_IP_SET_NAME}"
    log_message "Creating temporary IPSet: ${TEMP_IP_SET_NAME}"
    run_pvesh_modify create /cluster/firewall/ipset --name "${TEMP_IP_SET_NAME}" --comment "Cloudflare IPs (Staging)"

    log_message "Populating temporary IPSet with new IPs..."
    local ip_count=0
    for ip in ${all_cf_ips}; do
        run_pvesh_modify create /cluster/firewall/ipset/${TEMP_IP_SET_NAME} --cidr "${ip}"
        ip_count=$((ip_count + 1))
    done
    log_message "Added ${ip_count} IPs to the temporary IPSet."

    # --- 4. Compare and Update ---
    log_message "Comparing new list with the existing IPSet..."
    local current_ips new_ips
    # Ensure the main IPSet exists before trying to get its contents
    if ! pvesh get /cluster/firewall/ipset/${IP_SET_NAME} >/dev/null 2>&1; then
        log_message "Main IPSet '${IP_SET_NAME}' does not exist. Creating it now."
        run_pvesh_modify create /cluster/firewall/ipset --name "${IP_SET_NAME}" --comment "Cloudflare IPs (Production)"
    fi
    current_ips=$(pvesh get /cluster/firewall/ipset/${IP_SET_NAME}/ --output-format json | jq -r '.[].cidr' | sort)
    new_ips=$(pvesh get /cluster/firewall/ipset/${TEMP_IP_SET_NAME}/ --output-format json | jq -r '.[].cidr' | sort)

    if [ "${current_ips}" == "${new_ips}" ]; then
        log_message "IP ranges are already up-to-date. No changes needed."
        exit 0
    fi

    # --- 5. Perform Differential Update (Add/Remove IPs) ---
    log_message "IP ranges have changed. Performing differential update..."

    # Calculate which IPs to add and which to remove using `comm`.
    local ips_to_add
    ips_to_add=$(comm -13 <(echo "${current_ips}") <(echo "${new_ips}"))

    local ips_to_remove
    ips_to_remove=$(comm -23 <(echo "${current_ips}") <(echo "${new_ips}"))

    # Add new IPs if any exist
    if [[ -n "$ips_to_add" ]]; then
        log_message "Adding new IPs to '${IP_SET_NAME}'..."
        local add_count=0
        for ip in $ips_to_add; do
            run_pvesh_modify create /cluster/firewall/ipset/${IP_SET_NAME} --cidr "${ip}"
            add_count=$((add_count + 1))
        done
        log_message "Added ${add_count} new IPs."
    else
        log_message "No new IPs to add."
    fi

    # Remove stale IPs if any exist
    if [[ -n "$ips_to_remove" ]]; then
        log_message "Removing stale IPs from '${IP_SET_NAME}'..."
        local remove_count=0
        for ip in $ips_to_remove; do
            run_pvesh_modify delete "/cluster/firewall/ipset/${IP_SET_NAME}/${ip}"
            remove_count=$((remove_count + 1))
        done
        log_message "Removed ${remove_count} stale IPs."
    else
        log_message "No stale IPs to remove."
    fi

    log_message "Successfully updated the '${IP_SET_NAME}' IPSet."
}

# Execute the main function.
main
