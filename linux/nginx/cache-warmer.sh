#!/usr/bin/env bash
# cache-warmer.sh
# =================================================================
# URL Cache Warmer Script
# Copyright (c) 2025-2026 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
# =================================================================
# This script fetches a list of URLs from a specified text file,
# extracts the URLs from markdown-style text, and then uses curl
# to "warm up" the Nginx FastCGI cache for each URL.
#
# It performs the following actions:
# 1. Checks for required dependencies (curl, grep, sed, tr).
# 2. Fetches and parses a remote list of URLs.
# 3. For each URL, it makes a request DIRECTLY TO THE ORIGIN (bypassing any
#    CDN/reverse-proxy such as Cloudflare) and displays the headers.
# 4. The cache status line is color-coded for readability (HIT, MISS, etc.).
# 5. If the cache status is 'MISS', it will re-run the check up to a defined limit.
#
# **Why bypass the CDN?**
# When a CDN (e.g. Cloudflare with APO) edge-caches the HTML, requests through
# the public hostname are served from the CDN edge and never reach the origin.
# The 'x-fastcgi-cache' header in that cached copy is frozen at whatever value
# the origin returned on the first (cold) hit -- typically MISS -- so the warmer
# would see a permanent MISS even though the origin FastCGI cache is healthy.
# Resolving the hostname to the origin IP makes curl talk to Nginx directly, so
# the warmer actually warms and reports the origin cache. The cache key
# ("$scheme$request_method$host$request_uri") is identical to real CDN->origin
# traffic because the SNI/Host header stays the real hostname.
#
# Usage:
#   ./cache-warmer.sh [ORIGIN_IP]
#
#   ORIGIN_IP  (optional) IP address to resolve the site's hostname to.
#              Defaults to 127.0.0.1 because this script is intended to run on
#              the origin host itself. Pass another IP to warm a remote origin.
# =================================================================

# --- User-defined Variables ---

# The URL of the text file containing the list of URLs to check.
readonly URL_LIST="https://example.com/llms.txt"
# The maximum number of times to retry a URL if it keeps returning a cache MISS.
readonly MAX_RETRIES=5
# IP address the site's hostname is resolved to, so requests bypass the CDN and
# hit the origin Nginx directly. This is the human-readable default; it can be
# overridden at runtime by passing an IP as the first argument (handled in main).
readonly ORIGIN_IP="127.0.0.1"

# --- Script Configuration ---
# Exit on error, treat unset variables as an error, and fail on piped command errors.
set -o errexit -o nounset -o pipefail

# --- Color Definitions ---
# Only emit ANSI color codes when stdout is an interactive terminal, so cron logs
# and redirected output stay free of escape sequences.
if [[ -t 1 ]]; then
    readonly COLOR_RED=$'\033[0;31m'
    readonly COLOR_GREEN=$'\033[0;32m'
    readonly COLOR_YELLOW=$'\033[0;33m'
    readonly COLOR_RESET=$'\033[0m'
else
    readonly COLOR_RED=""
    readonly COLOR_GREEN=""
    readonly COLOR_YELLOW=""
    readonly COLOR_RESET=""
fi

# --- Helper Functions ---

# Derive the host and port from a URL, defaulting the port from the scheme.
# Sets the global variables RESOLVE_HOST and RESOLVE_PORT.
parse_host_port() {
    local url="$1" proto rest hostport
    proto="${url%%://*}"     # http or https
    rest="${url#*://}"       # strip scheme
    hostport="${rest%%/*}"   # host[:port]
    if [[ "$hostport" == *:* ]]; then
        RESOLVE_HOST="${hostport%%:*}"
        RESOLVE_PORT="${hostport##*:}"
    else
        RESOLVE_HOST="$hostport"
        if [[ "$proto" == "https" ]]; then
            RESOLVE_PORT=443
        else
            RESOLVE_PORT=80
        fi
    fi
}

# --- Main Script Logic ---
main() {
    # --- 1. Pre-flight Checks ---
    local dependencies=("curl" "grep" "sed" "tr")
    local cmd
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "FATAL: Required command '${cmd}' is not installed or not in PATH." >&2
            exit 1
        fi
    done

    # Apply an optional command-line override of the origin IP (first argument),
    # falling back to the human-readable default configured at the top.
    local origin_ip="${1:-$ORIGIN_IP}"

    echo "Warming origin cache via ${origin_ip} (CDN bypassed)."
    echo ""

    # --- 2. Fetch and Parse URL List ---
    # Fetch into a variable first so the parse loop runs in the current shell
    # (no subshell) and behaves correctly under 'set -o errexit -o pipefail'.
    echo "Fetching and parsing URLs from ${URL_LIST}..."
    echo ""

    local url_list_raw urls
    if ! url_list_raw=$(curl -sL "${URL_LIST}"); then
        echo "FATAL: Could not fetch the URL list from ${URL_LIST}." >&2
        exit 1
    fi
    # 'grep' exits non-zero when nothing matches; tolerate that explicitly.
    urls=$(printf '%s\n' "${url_list_raw}" | grep -oE 'https?://[^)]+') || true
    if [[ -z "${urls}" ]]; then
        echo "WARNING: No URLs found in ${URL_LIST}. Nothing to warm." >&2
        exit 0
    fi

    # --- 3. Warm Each URL Against the Origin ---
    local url
    while IFS= read -r url; do
        if [[ -z "$url" ]]; then
            continue
        fi

        echo "----------------------------------------"
        echo "Checking headers for: ${url}"
        echo "----------------------------------------"

        # Resolve this URL's hostname to the origin IP so the request bypasses
        # the CDN and warms/measures the origin Nginx FastCGI cache directly.
        parse_host_port "$url"

        local retry_count=0
        while true; do
            local headers
            # Tolerate a curl failure (|| true) so the loop can report it rather
            # than aborting the whole script under 'set -o errexit'.
            headers=$(curl -sL --resolve "${RESOLVE_HOST}:${RESOLVE_PORT}:${origin_ip}" -o /dev/null -D - "$url" | tr -d '\r') || true

            # Colorize the cache-status line for readability.
            sed \
                -e "/x-fastcgi-cache:.*[Hh][Ii][Tt]/s/.*/${COLOR_GREEN}&${COLOR_RESET}/" \
                -e "/x-fastcgi-cache:.*[Mm][Ii][Ss][Ss]/s/.*/${COLOR_RED}&${COLOR_RESET}/" \
                -e "/x-fastcgi-cache:.*[Bb][Yy][Pp][Aa][Ss][Ss]/s/.*/${COLOR_YELLOW}&${COLOR_RESET}/" <<< "${headers}"

            if grep -iqE 'x-fastcgi-cache:[[:space:]]*MISS' <<< "${headers}"; then
                retry_count=$((retry_count + 1))

                if [[ "$retry_count" -ge "$MAX_RETRIES" ]]; then
                    echo "--> ${COLOR_YELLOW}WARNING: Max retries reached for this URL. Moving on.${COLOR_RESET}"
                    break
                fi

                echo "--> Cache MISS detected. Retrying in 1 second... (${retry_count}/${MAX_RETRIES})"
                sleep 1
            elif grep -iqE 'x-fastcgi-cache:[[:space:]]*(HIT|BYPASS)' <<< "${headers}"; then
                echo "--> Cache is now HIT or BYPASS. Moving to the next URL."
                echo ""
                break # Exit the inner `while true` loop
            else
                # No recognizable cache status: origin unreachable or response not
                # served by the FastCGI cache. Warn instead of claiming success.
                echo "--> ${COLOR_YELLOW}WARNING: No x-fastcgi-cache status returned (origin unreachable or non-cacheable). Moving on.${COLOR_RESET}"
                echo ""
                break
            fi
        done
    done <<< "${urls}"

    echo "Script finished."
}

# Execute the main function, passing all script arguments to it.
main "$@"
