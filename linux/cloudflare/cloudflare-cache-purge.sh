#!/usr/bin/env bash
# cloudflare-cache-purge.sh
# =================================================================
# Cloudflare Cache Management Tool
# Copyright (c) 2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
# =================================================================
# A script to purge the Cloudflare cache for a specific zone, with
# support for both interactive and non-interactive (flag-based) operation.
#
# Features:
# - Purge the entire zone cache.
# - Purge specific URLs from a remote list.
# - Purge a single URL.
# - Interactive mode for guided use.
# - Non-interactive mode using command-line flags for automation.
# - Dependency check for required tools (curl, jq).
#
# Usage:
# 1.  Fill in your credentials in the "Configuration" section below.
# 2.  Make the script executable:
#     chmod +x cloudflare-cache-purge.sh
#
# Example Commands:
# - Run in interactive mode:
#   ./cloudflare-cache-purge.sh
#
# - Purge the entire zone without asking for confirmation:
#   ./cloudflare-cache-purge.sh --zone --yes
#
# - Purge a single URL:
#   ./cloudflare-cache-purge.sh --url https://example.com/some-page
#
# - Show the help message:
#   ./cloudflare-cache-purge.sh --help
# =================================================================

# --- Configuration ---
# REQUIRED: Get this from your Cloudflare dashboard.
CLOUDFLARE_API_TOKEN="YOUR_API_TOKEN"

# OPTIONAL: You can set the Zone ID here. If you leave it blank or as the
# default placeholder, the script will ask you to enter it when you run it.
CLOUDFLARE_ZONE_ID="YOUR_ZONE_ID"

# The URL of the text file containing the list of URLs to purge.
readonly URL_LIST="https://ramon.vanraaij.eu/llms.txt"

# --- Script Configuration ---
# Exit on error, treat unset variables as an error, and fail on piped command errors.
set -o errexit -o nounset -o pipefail

# --- Core Functions ---

# Logs a message to the console with a timestamp.
log_message() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

# Shows the help message for command-line flags.
show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -u, --url URL      Purge a single URL from the cache."
    echo "  -l, --list         Purge all URLs found in the remote list."
    echo "  -z, --zone         Purge the entire cache for the zone."
    echo "  -y, --yes          Skip confirmation prompts for list and zone purges."
    echo "  -h, --help         Show this help message."
    echo ""
    echo "If no options are provided, the script will run in interactive mode."
}

# Checks for a command and exits if it's not found.
check_dependency() {
    local command_name="$1"
    local package_name="$2"
    local description="$3"

    if ! command -v "${command_name}" &>/dev/null; then
        log_message "FATAL: Dependency missing: ${description}" >&2
        log_message "Please install '${package_name}' using your system's package manager and try again." >&2
        exit 1
    fi
}

# --- Cloudflare API Functions ---

# Central function to make API calls to Cloudflare.
# $1: JSON payload for the request body.
cloudflare_api_call() {
    local payload="$1"
    local api_url="https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/purge_cache"

    log_message "Sending purge request to Cloudflare API..."
    
    local response
    response=$(curl --request POST \
        --url "${api_url}" \
        --header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        --header "Content-Type: application/json" \
        --data "${payload}" \
        --silent)

    if ! echo "${response}" | jq -e '.success == true' >/dev/null; then
        log_message "ERROR: Cloudflare API call failed."
        log_message "API Response:"
        echo "${response}" | jq '.'
        return 1
    else
        log_message "SUCCESS: Cloudflare API reports cache purge was successful."
        return 0
    fi
}

# Purges a list of URLs. Cloudflare API allows up to 30 files per request.
purge_url_list() {
    local -a urls_to_purge=($@)
    if [[ ${#urls_to_purge[@]} -eq 0 ]]; then
        log_message "WARNING: No URLs provided to purge."
        return
    fi
    
    for ((i = 0; i < ${#urls_to_purge[@]}; i += 30)); do
        local batch=("${urls_to_purge[@]:i:30}")
        log_message "Purging batch of ${#batch[@]} URLs..."
        
        local payload
        payload=$(printf '%s\n' "${batch[@]}" | jq -R . | jq -s '{"files": .}')
        
        if ! cloudflare_api_call "${payload}"; then
            log_message "ERROR: A batch failed to purge. Halting further purge attempts."
            exit 1
        fi
    done
}

# --- Action Functions ---

action_purge_list() {
    local skip_confirmation=${1:-false}
    log_message "Fetching URLs from remote list..."
    local remote_content
    if ! remote_content=$(curl --fail -sL "${URL_LIST}"); then
        log_message "FATAL: Failed to fetch the URL list. Please check the URL and your network." >&2; exit 1
    fi
    local -a urls
    mapfile -t urls < <(echo "${remote_content}" | grep -oE 'https?://[^)]+')
    
    if [[ ${#urls[@]} -eq 0 ]]; then
        log_message "WARNING: No URLs were found in the remote file. Exiting."
        exit 0
    fi
    
    log_message "Found ${#urls[@]} URLs to purge from the list."
    
    local confirm="no"
    if [[ "${skip_confirmation}" == true ]]; then
        confirm="yes"
    else
        read -p "Are you sure you want to purge all these URLs? (yes/no): " confirm
    fi

    if [[ "${confirm}" == "yes" ]]; then
        purge_url_list "${urls[@]}"
    else
        log_message "Operation cancelled."
    fi
}

action_purge_zone() {
    local skip_confirmation=${1:-false}
    local confirm="no"
    if [[ "${skip_confirmation}" == true ]]; then
        confirm="yes"
    else
        read -p "This will DELETE the ENTIRE Cloudflare cache for your zone. This action cannot be undone. Are you absolutely sure? (yes/no): " confirm
    fi

    if [[ "${confirm}" == "yes" ]]; then
        if ! cloudflare_api_call '{"purge_everything":true}'; then
            exit 1
        fi
    else
        log_message "Operation cancelled."
    fi
}

# --- Main Logic ---

run_interactive_mode() {
    echo ""
    echo "Cloudflare Cache Management Tool"
    echo "--------------------------------"
    echo "1. Clear cache for a single URL"
    echo "2. Clear cache for all URLs in the remote list (${URL_LIST})"
    echo "3. Clear the ENTIRE cache for the zone (Purge Everything)"
    read -p "Enter your choice (1, 2, or 3): " choice

    case ${choice} in
        1)
            read -p "Enter the full URL to clear: " url_to_clear
            if [[ ! "${url_to_clear}" =~ ^https?:// ]]; then
                log_message "ERROR: The URL must start with 'http://' or 'https://'." >&2; exit 1;
            fi
            purge_url_list "${url_to_clear}"
            ;;
        2)
            action_purge_list
            ;;
        3)
            action_purge_zone
            ;;
        *)
            log_message "Invalid choice. Please enter 1, 2, or 3." >&2; exit 1;
            ;;
    esac
}

main() {
    log_message "--- Starting Cloudflare Cache Management Tool ---"
    check_dependency "curl" "curl" "'curl' is required to make API calls."
    check_dependency "jq" "jq" "'jq' is required to safely parse API responses."

    # --- Load and Validate Credentials ---
    if [[ "${CLOUDFLARE_API_TOKEN}" == "YOUR_API_TOKEN" || -z "${CLOUDFLARE_API_TOKEN}" ]]; then
        log_message "FATAL: Cloudflare API Token is not set." >&2
        log_message "Please edit the script and set the CLOUDFLARE_API_TOKEN variable." >&2
        exit 1
    fi

    if [[ "${CLOUDFLARE_ZONE_ID}" == "YOUR_ZONE_ID" || -z "${CLOUDFLARE_ZONE_ID}" ]]; then
        if [[ $# -eq 0 ]]; then # Interactive mode: prompt the user.
            read -p "Cloudflare Zone ID is not configured. Please enter it now: " CLOUDFLARE_ZONE_ID
            # Re-check after prompting
            if [[ -z "${CLOUDFLARE_ZONE_ID}" || "${CLOUDFLARE_ZONE_ID}" == "YOUR_ZONE_ID" ]]; then
                log_message "FATAL: A valid Cloudflare Zone ID is required to proceed." >&2
                exit 1
            fi
        else # Non-interactive mode: Zone ID must be pre-configured.
            log_message "FATAL: Cloudflare Zone ID is not configured for non-interactive use." >&2
            log_message "Please set the CLOUDFLARE_ZONE_ID variable in the script before using flags." >&2
            exit 1
        fi
    fi

    readonly CLOUDFLARE_API_TOKEN
    readonly CLOUDFLARE_ZONE_ID

    # --- Argument Parsing ---
    if [[ $# -gt 0 ]]; then
        local mode=""
        local url_to_clear=""
        local skip_confirmation=false

        while [[ $# -gt 0 ]]; do
            key="$1"
            case ${key} in
                -h|--help)
                    show_help
                    exit 0
                    ;; 
                -u|--url)
                    mode="url"
                    if [[ -z "${2:-}" ]]; then log_message "ERROR: --url requires a URL as an argument." >&2; exit 1; fi
                    url_to_clear="$2"
                    shift; shift
                    ;; 
                -l|--list)
                    mode="list"
                    shift
                    ;; 
                -z|--zone)
                    mode="zone"
                    shift
                    ;; 
                -y|--yes)
                    skip_confirmation=true
                    shift
                    ;; 
                *)
                    log_message "ERROR: Unknown option '$1'" >&2
                    show_help
                    exit 1
                    ;; 
            esac
        done

        case ${mode} in
            url)
                if [[ ! "${url_to_clear}" =~ ^https?:// ]]; then
                    log_message "ERROR: The URL must start with 'http://' or 'https://'." >&2; exit 1;
                fi
                purge_url_list "${url_to_clear}"
                ;; 
            list)
                action_purge_list "${skip_confirmation}"
                ;; 
            zone)
                action_purge_zone "${skip_confirmation}"
                ;; 
            *)
                log_message "ERROR: No action specified. Please use -u, -l, or -z." >&2
                show_help
                exit 1
                ;; 
        esac
    else
        run_interactive_mode
    fi

    log_message "--- Operation complete ---"
}

# Execute the main function, passing all script arguments to it.
main "$@"