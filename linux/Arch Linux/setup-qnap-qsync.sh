#!/usr/bin/env bash
# setup-qnap-qsync.sh
# =================================================================
# QNAP Qsync Client Setup
#
# Copyright (c) 2024-2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script sets up the QNAP Qsync client on Arch Linux. It downloads
# the latest Ubuntu .deb package from QNAP's servers, converts it to 
# Arch Linux format using debtap, and installs it.
#
# It performs the following actions:
# 1. Ensures all required dependencies are installed
# 2. Downloads the latest Qsync client from QNAP's servers
# 3. Converts the .deb package to .pkg.tar.zst format using debtap
# 4. Installs the converted package with necessary dependency assumptions
# 5. Cleans up downloaded files
#
# **Note:**
# This script relies on `debtap` for conversion, which might not guarantee 
# perfect compatibility. The installation involves converting a .deb package
# to Arch format, which may have unexpected side effects.
# =================================================================

# --- Script Configuration ---
# Exit on error, treat unset variables as an error, and fail on piped command errors.
set -o errexit -o nounset -o pipefail

# =================================================================
# --- User Configuration ---
# Please edit the variables in this section if needed.
# =================================================================

# URL for QNAP's software release XML
readonly QNAP_RELEASE_URL="https://update.qnap.com/SoftwareRelease.xml"

# Download directory (defaults to current directory)
readonly DOWNLOAD_DIR="${DOWNLOAD_DIR:-$(pwd)}"

# Name for the downloaded package file
readonly DOWNLOAD_FILE="QNAPQsyncClientUbuntux64.deb"

# Dependencies required for script execution
readonly QSYNC_DEPENDENCIES="debtap curl wget libxml2 pacman-contrib debugedit"

# Dependencies to assume installed when installing the Qsync package
readonly ASSUME_INSTALLED_DEPS="android-emulator anaconda plex-media-server activitywatch-bin cura-bin clion fcitx-qt5"

# =================================================================
# --- Do Not Edit Below This Line ---
# =================================================================

original_dir=$(pwd)

# --- Functions ---

# Logs a message to the console with a timestamp.
log_message() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

# Ensures the temporary directory is always removed when the script exits.
cleanup() {
    cd "$original_dir"
    # Clean up downloaded .deb file as well
    if [ -f "${DOWNLOAD_FILE}" ]; then
        rm -f "${DOWNLOAD_FILE}"
        log_message "Cleaned up downloaded .deb file."
    fi
    
    # Clean up generated PKGBUILD directory
    local pkgbuild_dir
    pkgbuild_dir=$(find . -maxdepth 1 -type d -name "*-PKGBUILD" | head -n 1)
    
    if [ -n "$pkgbuild_dir" ]; then
        rm -rf "$pkgbuild_dir"
        log_message "Cleaned up generated PKGBUILD directory."
    fi
}

# Checks if the script is run with sudo privileges (only needed for installation)
check_sudo() {
    if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
        log_message "Script requires sudo privileges for installation."
        return 0  # Just notify that sudo may be needed
    fi
}

# Ensures all required external commands are available before proceeding
check_dependencies() {
    local missing_deps=()
    for pkg in $QSYNC_DEPENDENCIES; do
        if ! pacman -Q "$pkg" >/dev/null 2>&1; then
            missing_deps+=("$pkg")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_message "Installing missing dependencies: ${missing_deps[*]}"
        if command -v sudo >/dev/null 2>&1 && sudo -v; then
            sudo pacman -S --needed --noconfirm "${missing_deps[@]}"
        else
            log_message "FATAL: Cannot install dependencies without sudo access." >&2
            exit 1
        fi
    fi
    log_message "All required dependencies are installed."
}

# Updates debtap database to ensure it's current
update_debtap() {
    log_message "Updating debtap database..."
    sudo debtap -u
    log_message "Debtap database updated."
}

# Determines the download URL for QNAP Qsync client
get_download_url() {
    # Extract the URL and use a function to clean it
    local raw_url
    raw_url=$(curl -sL "${QNAP_RELEASE_URL}" | \
          xmllint --xpath '//application[applicationName="com.qnap.qsync"]/platform[platformName="Ubuntu"]/software/downloadURL[1]' - 2>/dev/null | \
          sed -e 's/<[^>]*>//g')
    
    # Clean the URL more carefully to avoid control characters
    local url
    # Use parameter expansion to remove leading/trailing whitespace
    url=$(printf '%s' "$raw_url" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    
    if [ -z "$url" ]; then
        log_message "FATAL: Could not retrieve download URL for QNAP Qsync client." >&2
        exit 1
    fi
    
    # Validate that the URL starts with http
    if [[ ! "$url" =~ ^https?:// ]]; then
        log_message "FATAL: Extracted URL is not valid: $url" >&2
        exit 1
    fi
    
    echo "$url"
}

# Downloads the Qsync client package from QNAP's servers
download_qsync_package() {
    log_message "Fetching download URL for QNAP Qsync client..."
    local download_url
    download_url=$(get_download_url)
    log_message "Found download URL: $download_url"
    
    log_message "Downloading QNAP Qsync client package..."
    
    # Double check that the URL is properly formatted
    if [[ ! "$download_url" =~ ^https?:// ]]; then
        log_message "FATAL: Download URL is not valid: $download_url" >&2
        exit 1
    fi
    
    log_message "Attempting to download from: $download_url"
    
    if ! wget -O "${DOWNLOAD_FILE}" "$download_url"; then
        log_message "FATAL: Failed to download QNAP Qsync client package." >&2
        exit 1
    fi
    
    log_message "QNAP Qsync client package downloaded successfully."
}

# Converts the .deb package to .pkg.tar.zst format using debtap
convert_package() {
    log_message "Converting Ubuntu package to Arch format..."
    
    # Generate a PKGBUILD from the .deb package using debtap (Pkgbuild only)
    if ! debtap -Q -P "${DOWNLOAD_FILE}"; then
        log_message "FATAL: Failed to generate PKGBUILD for QNAP Qsync client package." >&2
        exit 1
    fi
    
    # Find the generated PKGBUILD directory and navigate to it
    local pkgbuild_dir
    pkgbuild_dir=$(find . -maxdepth 1 -type d -name "*-PKGBUILD" | head -n 1)
    
    if [ -z "$pkgbuild_dir" ]; then
        log_message "FATAL: PKGBUILD directory not found." >&2
        exit 1
    fi
    
    # Change to the PKGBUILD directory
    cd "$pkgbuild_dir"

    # Copy the .deb file into the build directory
    cp "../${DOWNLOAD_FILE}" .
    
    # Store the original install file name
    local original_install_file
    original_install_file=$(ls *.install 2>/dev/null | head -n 1)
    
    # Modify the generated PKGBUILD to set the correct package name and epoch
    sed -i 's/^pkgname=.*/pkgname=qsync/' PKGBUILD
    sed -i 's/^epoch=.*/epoch=1/' PKGBUILD

    # Remove unused i686 sources and point to the correct .deb file
    sed -i '/^source_i686=/d' PKGBUILD
    sed -i '/^sha512sums_i686=/d' PKGBUILD
    sed -i "s|source_x86_64=.*|source_x86_64=(\"${DOWNLOAD_FILE}\")|" PKGBUILD
    
    # Fix empty license and groups fields that cause makepkg to fail
    sed -i 's/^license=.*$/license=("custom")/' PKGBUILD
    sed -i '/^groups=/d' PKGBUILD

    # Disable debug package creation
    sed -i "s/^options=.*$/options=('!strip' '!emptydirs' '!debug')/" PKGBUILD

    # Remove dependencies from PKGBUILD as they are incorrect
    sed -i '/^depends=/,/)/d' PKGBUILD

    # Fix package() function by commenting out the failing install command
    sed -i 's|install -D -m644 "usr/local/bin/QNAP/QsyncClient/Licenses".*|# License installation disabled|' PKGBUILD
    
    # Update the install file reference if there was an install file
    if [ -n "$original_install_file" ]; then
        # Rename the install file to match the new package name
        local new_install_file="qsync.install"
        mv "$original_install_file" "$new_install_file"
        # Update the PKGBUILD to reference the new install file name
        sed -i "s/install=\${pkgname}.install/install=${new_install_file}/" PKGBUILD

        # Make the install script non-interactive by commenting out the reboot prompt
        sed -i "/if \[ \$NOTIFYREBOOT == 'Y' \]/,/fi/s/^/#/" "$new_install_file"
    else
        # Remove the install reference if no install file exists
        sed -i '/install=\${pkgname}.install/d' PKGBUILD
    fi
    
    # Build the package with the corrected PKGBUILD
    if ! makepkg -f --noconfirm --nodeps; then
        log_message "FATAL: Failed to build QNAP Qsync client package with corrected PKGBUILD." >&2
        exit 1
    fi
    
    log_message "Package converted successfully."
}

# Installs the converted Qsync client package
install_qsync_package() {
    log_message "Installing QNAP Qsync client..."
    
    # Look in the PKGBUILD directory for the package file
    local pkgbuild_dir
    pkgbuild_dir=$(find . -maxdepth 1 -type d -name "*-PKGBUILD" | head -n 1)
    
    if [ -z "$pkgbuild_dir" ]; then
        log_message "FATAL: PKGBUILD directory not found." >&2
        exit 1
    fi
    
    # Change to the PKGBUILD directory to look for the package file
    local pkg_file
    pkg_file=$(find "$pkgbuild_dir" -type f -name 'qsync-*.pkg.tar.zst' | head -n 1)
    
    # If still not found, try with the alternative naming pattern
    if [ -z "$pkg_file" ]; then
        pkg_file=$(find "$pkgbuild_dir" -type f -name '*.pkg.tar.zst' | head -n 1)
    fi
    
    if [ -z "$pkg_file" ]; then
        log_message "FATAL: Converted package file not found." >&2
        exit 1
    fi
    
    log_message "Found package file: $pkg_file"
    
    # Install the package with assumed dependencies
    local assume_args=()
    for dep in $ASSUME_INSTALLED_DEPS; do
        assume_args+=("--assume-installed" "$dep")
    done

    if ! sudo pacman -U --noconfirm "${assume_args[@]}" "$pkg_file"; then
        log_message "FATAL: Failed to install QNAP Qsync client package." >&2
        exit 1
    fi
    
    log_message "QNAP Qsync client installed successfully."
}

# --- Main script logic ---
main() {
    log_message "--- Starting QNAP Qsync setup ---"
    
    # Register the cleanup function to be called on any script exit
    trap cleanup EXIT
    
    # Perform pre-flight checks
    check_sudo
    check_dependencies
    
    # Update debtap database
    update_debtap
    
    # Download the Qsync client package
    download_qsync_package
    
    # Convert the package to Arch format
    convert_package
    
    # Return to original directory before installation
    cd "$original_dir"
    
    # Install the converted package
    install_qsync_package
    
    log_message "QNAP Qsync client has been successfully installed."
    log_message "You can now launch QNAP Qsync from your application menu."
}

# Execute the main function
main

