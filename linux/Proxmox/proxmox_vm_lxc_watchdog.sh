#!/usr/bin/env bash
# proxmox_vm_lxc_watchdog.sh
# =================================================================
# Proxmox VM/Container Auto-Starter with Email Notifications
#
# Copyright (c) 2026 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script monitors the status of Proxmox VMs (Qemu) and 
# Containers (LXC). It ensures that resources configured to start 
# on boot are running, automatically restarting them if they are 
# stopped and not locked.
#
# It performs the following actions:
# 1. Validates dependencies (qm, pct, pvesh, mail, awk, jq).
# 2. Fetches resource IDs (all, specific, or default list).
# 3. Checks the status of each VM/Container.
# 4. Verifies 'onboot' configuration and 'lock' status.
# 5. Starts stopped resources that are configured for 'onboot'.
# 6. Sends email notifications on success or failure of auto-starts.
#
# Usage:
#   ./check_vm_status.sh all            # Check ALL resources
#   ./check_vm_status.sh 110 115        # Check specific IDs
#
# **Note:**
# Requires `mailutils` or a similar 'mail' command configured on 
# the Proxmox host to send external notifications.
# =================================================================

# --- Script Configuration ---
set -o errexit -o nounset -o pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- User Configuration ---
# The email address where notifications will be sent.
readonly EMAIL_RECIPIENT="YOUR_EMAIL_HERE"

# Default list of VM/CT IDs to check if no arguments are passed.
# Monitoring 110 (HA) and 115 (MicroOS)
readonly DEFAULT_VMS=(110 115)

# Exclusion list: These IDs will ALWAYS be skipped.
readonly EXCLUDE_VMS=()

# --- Terminal Output Styling ---
# Define color variables for styled terminal output if supported.
if command -v tput >/dev/null 2>&1 && tput setaf 1 >/dev/null 2>&1; then
    readonly GREEN=$(tput setaf 2)
    readonly RED=$(tput setaf 1)
    readonly YELLOW=$(tput setaf 3)
    readonly NORMAL=$(tput sgr0)
else
    readonly GREEN=""
    readonly RED=""
    readonly YELLOW=""
    readonly NORMAL=""
fi

# --- Core Functions ---

# Logs a message to the console with a timestamp and color.
# Parameters:
#   $1 - color variable (e.g., $RED, $GREEN)
#   $2 - message string
log_message() {
    local color="$1"
    local message="$2"
    printf "${color}[%s] %s${NORMAL}\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$message"
}

# Sends an email notification using the 'mail' command.
# Parameters:
#   $1 - subject string
#   $2 - body string
send_notification() {
    local subject="$1"
    local body="$2"
    
    # Do not attempt to send if email is not configured.
    if [[ -z "${EMAIL_RECIPIENT}" ]] || [[ "${EMAIL_RECIPIENT}" == "YOUR_EMAIL_HERE" ]]; then
        return
    fi

    log_message "${YELLOW}" "Sending email notification to ${EMAIL_RECIPIENT}..."
    # Ensure postfix/mailutils is correctly configured on the PVE host.
    echo "${body}" | mail -s "${subject}" "${EMAIL_RECIPIENT}" || log_message "${RED}" "Email failed."
}

# Returns 0 if the provided ID is in the exclusion list.
# Parameters:
#   $1 - VM/CT ID
is_excluded() {
    local id="$1"
    for excluded in "${EXCLUDE_VMS[@]}"; do
        [[ "$id" == "$excluded" ]] && return 0
    done
    return 1
}

# --- Main Script Logic ---
main() {
    # 1. Pre-flight Checks
    # Verify all required binaries are available in the PATH.
    local dependencies="qm pct pvesh mail awk jq"
    for cmd in $dependencies; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_message "${RED}" "FATAL: Required command '${cmd}' missing."
            exit 1
        fi
    done

    # 2. Determine which IDs to process
    local vms_to_check=()
    if [[ "${1:-}" == "all" ]]; then
        log_message "${YELLOW}" "Fetching ALL cluster resources..."
        # Use pvesh to get all qemu and lxc resources from the cluster.
        mapfile -t vms_to_check < <(pvesh get /cluster/resources --output-format json | jq -r '.[] | select(.type=="lxc" or .type=="qemu") | .vmid')
    elif [[ "$#" -gt 0 ]]; then
        # Use provided arguments as IDs.
        vms_to_check=("$@")
    else
        # Fall back to the default list in configuration.
        vms_to_check=("${DEFAULT_VMS[@]}")
    fi

    # 3. Iterate through IDs and process status
    for vmid in "${vms_to_check[@]}"; do
        # Validate that ID is numeric and not in the exclusion list.
        if ! [[ "$vmid" =~ ^[0-9]+$ ]] || is_excluded "$vmid"; then
            continue
        fi

        # Determine if the resource is a VM (qemu) or a Container (lxc).
        local type=""
        local cmd=""
        local resource_json
        resource_json=$(pvesh get /cluster/resources --output-format json | jq -r ".[] | select(.vmid == $vmid)")
        
        if [[ -z "$resource_json" ]]; then
             log_message "${RED}" "ID $vmid not found in cluster resources."
             continue
        fi

        type=$(echo "$resource_json" | jq -r ".type")

        case "$type" in
            qemu) cmd="qm" ;; 
            lxc)  cmd="pct" ;; 
            *)    log_message "${YELLOW}" "ID $vmid is type '$type', skipping." ; continue ;; 
        esac

        # Check the current status of the resource.
        local current_status
        current_status=$($cmd status "$vmid" 2>/dev/null | awk '{print $2}')

        if [[ "$current_status" == "stopped" ]]; then
            # Fetch configuration to check 'onboot' and 'lock' status.
            local config_output=""
            if [[ "$cmd" == "qm" ]]; then
                config_output=$(qm config "$vmid")
            else
                config_output=$(pct config "$vmid")
            fi

            # Check if 'onboot: 1' is present in the configuration.
            local onboot="0"
            if echo "$config_output" | grep -q "^onboot: 1"; then
                onboot="1"
            fi
            
            # Check for any active locks (e.g., backup, migrate, rollback).
            local lock=""
            # Ensure grep failure doesn't exit the script due to 'set -e'.
            lock=$(echo "$config_output" | grep "^lock:" | awk '{print $2}' || true)

            # Auto-start logic: must be onboot=1 and NOT locked.
            if [[ "$onboot" == "1" ]] && [[ -z "$lock" ]]; then
                log_message "${YELLOW}" "$type $vmid is STOPPED and OnBoot is ENABLED. Starting..."
                
                # Attempt to start the resource.
                if $cmd start "$vmid"; then
                     log_message "${GREEN}" "$type $vmid started successfully."
                     send_notification "Proxmox Auto-Start: $type $vmid" "The resource $type $vmid was found stopped and has been started automatically by the watchdog script."
                else
                     log_message "${RED}" "Failed to start $type $vmid."
                     send_notification "Proxmox Auto-Start FAILED: $type $vmid" "The watchdog attempted to start $type $vmid but failed."
                fi
            elif [[ "$onboot" != "1" ]]; then
                log_message "${NORMAL}" "$type $vmid is stopped, but 'Start at boot' is disabled. No action taken."
            else
                log_message "${RED}" "$type $vmid is stopped but LOCKED ($lock). No action taken."
            fi
        else
            log_message "${GREEN}" "$type $vmid is $current_status."
        fi
    done
}

# --- Script Execution ---
main "$@"