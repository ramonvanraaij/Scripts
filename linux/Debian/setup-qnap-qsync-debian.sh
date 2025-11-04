#!/usr/bin/env bash
# setup-qnap-qsync-debian.sh
# =================================================================
# Install QNAP Qsync for Debian/Ubuntu
#
# Copyright (c) 2024 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script automates the installation of QNAP Qsync on
# Debian-based systems (like Ubuntu). It ensures all required
# dependencies are installed, fetches the latest version of
# Qsync, and handles the installation and cleanup process.
#
# It performs the following actions:
# 1. Checks for root privileges.
# 2. Verifies required command-line tools are installed.
# 3. Installs Qsync dependencies.
# 4. Fetches the latest download URL from QNAP's official XML feed.
# 5. Downloads the .deb package to a temporary file.
# 6. Installs the package and resolves any broken dependencies.
# 7. Cleans up temporary files.
#
# **Note:**
# Make sure to set execute permissions: chmod +x setup-qnap-qsync-debian.sh
# =================================================================

# Strict mode
set -o errexit -o nounset -o pipefail

# --- Configuration ---
# Dependencies required by this script
readonly SCRIPT_DEPENDENCIES="curl wget xmllint"

# Dependencies required by Qsync
readonly QSYNC_DEPENDENCIES="libasound2 libxtst6 libnss3 libusb-1.0-0 qtwayland5"
# --- End Configuration ---

# --- Functions ---
log() {
    echo "INFO: $1"
}

error() {
    echo "ERROR: $1" >&2
    exit 1
}
# --- End Functions ---

# --- Core Functions ---
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "This script must be run as root. Please use 'sudo'."
    fi
}

check_dependencies() {
    for cmd in $1; do
        if ! command -v "$cmd" &> /dev/null; then
            error "This script requires '$cmd' to be installed. Please install it and try again."
        fi
    done
}

main() {
    check_root

    log "Checking for required script dependencies..."
    check_dependencies "${SCRIPT_DEPENDENCIES}"

    log "Updating package lists..."
    apt-get update

    log "Installing Qsync dependencies..."
    apt-get install -y ${QSYNC_DEPENDENCIES}

    log "Getting the latest Qsync download URL for Ubuntu (x64)..."
    DOWNLOAD_URL=$(curl -sL "https://update.qnap.com/SoftwareRelease.xml" | xmllint --xpath 'string(/docRoot/utility/application[applicationName="com.qnap.qsync"]/platform[platformName="Ubuntu"]/software/downloadURL)')

    if [[ -z "${DOWNLOAD_URL}" ]]; then
        error "Could not determine the download URL for Qsync."
    fi
    log "Download URL found: ${DOWNLOAD_URL}"

    TMP_DEB_FILE=$(mktemp --suffix=.deb)
    trap 'rm -f "${TMP_DEB_FILE}"' EXIT

    log "Downloading Qsync to a temporary file: ${TMP_DEB_FILE}..."
    wget -O "${TMP_DEB_FILE}" "${DOWNLOAD_URL}"

    log "Installing Qsync..."
    dpkg -i "${TMP_DEB_FILE}"

    log "Fixing potential dependency issues..."
    apt-get --fix-broken install -y

    log "QNAP Qsync installation complete."
}
# --- End Core Functions ---

# --- Script execution ---
main "$@"
# --- End Script execution ---