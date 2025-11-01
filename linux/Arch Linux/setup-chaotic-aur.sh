#!/usr/bin/env bash
# setup-chaotic-aur.sh
# =================================================================
# Arch Linux Chaotic AUR Setup
#
# Copyright (c) 2024-2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script sets up the Chaotic AUR repository for Arch Linux. Chaotic AUR is an 
# additional repository that provides pre-built packages from the AUR, managed by
# the Arch Linux chaotic-aur team.
#
# It performs the following actions:
# 1. Ensures the script is run with sudo privileges
# 2. Adds the Chaotic AUR GPG key to the keyring
# 3. Installs the Chaotic AUR keyring and mirrorlist packages
# 4. Adds the Chaotic AUR repository to /etc/pacman.conf
# 5. Updates package databases
#
# **Note:**
# Using AUR (Arch User Repository) packages can be riskier than official packages
# as they are not officially maintained. Ensure you trust the source of any package
# before installing it from the AUR.
# =================================================================

# --- Script Configuration ---
# Exit on error, treat unset variables as an error, and fail on piped command errors.
set -o errexit -o nounset -o pipefail

# =================================================================
# --- User Configuration ---
# Please edit the variables in this section if needed.
# =================================================================

# GPG key ID for Chaotic AUR
# Full fingerprint: 4C85 6566 2648 3495 9B20  990F 3056 5138 87B7 8AEB
readonly CHAOTIC_AUR_KEY_ID="3056513887B78AEB"

# Key server to use for fetching the key
readonly KEY_SERVER="keyserver.ubuntu.com"

# Path to pacman configuration file
readonly PACMAN_CONF="/etc/pacman.conf"

# Include file for chaotic mirrorlist
readonly CHAOTIC_MIRRORLIST="/etc/pacman.d/chaotic-mirrorlist"

# Name of the repository section in pacman.conf
readonly REPO_NAME="chaotic-aur"

# =================================================================
# --- Do Not Edit Below This Line ---
# =================================================================

# --- Functions ---

# Logs a message to the console with a timestamp.
log_message() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

# Check if the script is run with sudo privileges
check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        log_message "FATAL: This script must be run with sudo or as root." >&2
        exit 1
    fi
}

# Ensure all required external commands are available before proceeding
check_dependencies() {
    local dependencies="pacman pacman-key tee"
    for cmd in $dependencies; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_message "FATAL: Required command '${cmd}' is not installed or not in PATH." >&2
            exit 1
        fi
    done
    log_message "All required commands are present."
}

# Add Chaotic AUR key to the local keyring
add_chaotic_aur_key() {
    log_message "Adding Chaotic AUR key (ID: ${CHAOTIC_AUR_KEY_ID})..."
    
    # Ensure pacman keyring is properly initialized and populated
    if [ ! -d /etc/pacman.d/gnupg ]; then
        log_message "Initializing and populating pacman keyring..."
        pacman-key --init
        pacman-key --populate archlinux
    else
        # Even if the directory exists, the keyring might not be properly initialized
        # Check if we can perform local signing - if not, we might need to initialize
        if ! pacman-key --lsign-key "${CHAOTIC_AUR_KEY_ID}" 2>/dev/null; then
            log_message "Keyring directory exists but local signing not functional. Initializing master key..."
            pacman-key --init
            pacman-key --populate archlinux
        fi
    fi
    
    # For additional safety, ensure archlinux keys are populated 
    pacman-key --populate archlinux
    
    # Receive the key from keyserver
    if ! pacman-key --recv-key "${CHAOTIC_AUR_KEY_ID}" --keyserver "${KEY_SERVER}"; then
        log_message "Error: Failed to receive the Chaotic AUR key from keyserver."
        exit 1
    fi
    
    # Try to locally sign the key - this is necessary for package verification
    if ! pacman-key --lsign-key "${CHAOTIC_AUR_KEY_ID}" 2>/dev/null; then
        # If local signing fails, attempt to fix the keyring
        log_message "Local signing failed, attempting keyring recovery..."
        
        # Try refreshing all keys
        pacman-key --refresh-keys
        
        # Try local signing again
        if ! pacman-key --lsign-key "${CHAOTIC_AUR_KEY_ID}" 2>/dev/null; then
            log_message "Error: Could not locally sign the key. This is required for package verification."
            log_message "Your pacman keyring may need manual attention."
            log_message "Try running: pacman-key --init && pacman-key --populate archlinux"
            exit 1
        fi
    fi
    
    log_message "Successfully added and locally signed Chaotic AUR key."
}

# Install Chaotic AUR keyring and mirrorlist packages
install_chaotic_packages() {
    log_message "Installing Chaotic AUR keyring and mirrorlist packages..."
    pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
    pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
    log_message "Successfully installed Chaotic AUR packages."
}

# Add Chaotic AUR repository to pacman configuration
add_repository_to_pacman() {
    log_message "Adding ${REPO_NAME} repository to ${PACMAN_CONF}..."
    
    # Check if repository is already added
    if grep -q "^\[${REPO_NAME}\]$" "${PACMAN_CONF}"; then
        log_message "Repository ${REPO_NAME} already exists in ${PACMAN_CONF}. Skipping."
        return 0
    fi
    
    # Append the repository configuration to pacman.conf
    tee -a "${PACMAN_CONF}" << EOF
[${REPO_NAME}]
Include = ${CHAOTIC_MIRRORLIST}
EOF
    
    log_message "Successfully added ${REPO_NAME} repository to ${PACMAN_CONF}."
}

# Update package databases
update_package_databases() {
    log_message "Updating package databases..."
    pacman -Sy
    log_message "Successfully updated package databases."
}

# --- Main script logic ---
main() {
    log_message "--- Starting Chaotic AUR setup ---"
    
    # Perform pre-flight checks
    check_sudo
    check_dependencies
    
    # Add Chaotic AUR key
    add_chaotic_aur_key
    
    # Install Chaotic AUR packages
    install_chaotic_packages
    
    # Add repository to pacman configuration
    add_repository_to_pacman
    
    # Update package databases
    update_package_databases
    
    log_message "Chaotic AUR repository has been successfully set up."
    log_message "You can now install packages from Chaotic AUR using pacman."
}

# Execute the main function
main

