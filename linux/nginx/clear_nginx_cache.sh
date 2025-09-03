#!/bin/bash
# clear_nginx_cache.sh
# =================================================================
# NGINX Cache Management Tool
# Copyright (c) 2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
# =================================================================
# This script automates the process of managing the NGINX cache for
# a WordPress site. It provides options to clear the cache for a
# single URL or to clear the entire cache directory.
#
# It performs the following actions:
# 1. Checks for required dependencies like `curl` and WP-CLI.
# 2. Offers to install missing dependencies with user consent.
# 3. Flushes both the NGINX and WordPress internal caches.
# 4. For full cache clearing, it also restarts the NGINX service.
#
# Usage:
# 1. Make the script executable: chmod +x clear_nginx_cache.sh
# 2. Run the script with sudo:    sudo ./clear_nginx_cache.sh
# =================================================================

# NOTE: This script is designed for use on Alpine Linux.
# The `apk add` package installation commands must be adapted for
# other distributions (e.g., `apt-get install` for Debian/Ubuntu or
# `yum install` for CentOS/RHEL).

# --- CONFIGURATION ---
CACHE_PATH="/var/cache/nginx/example-site"
WP_PATH="/var/www/example.com/public_html"
WP_USER="www-data" # The system user that owns the WordPress files

# --- FUNCTIONS ---

# Checks for a dependency and offers to install it if missing.
check_and_install() {
    local command_name="$1"
    local package_name="$2"
    local message="$3"

    if ! command -v "$command_name" &> /dev/null; then
        echo "Dependency missing: $message"
        read -p "Would you like to attempt to install '$package_name' now? (y/n): " choice
        if [[ "$choice" == "y" ]]; then
            echo "Installing $package_name..."
            if ! sudo apk add "$package_name"; then
                echo "Error: Installation failed. Please install '$package_name' manually and try again." >&2
                exit 1
            fi
            echo "Success: $package_name has been installed."
        else
            echo "Installation declined. The script cannot continue without '$package_name'." >&2
            exit 1
        fi
    fi
}

# Checks for required tools and offers to install them if missing.
check_and_install_dependencies() {
    echo "--- Checking for required dependencies ---"
    
    # Check for curl
    check_and_install "curl" "curl" "'curl' is required to download WP-CLI."
    
    # Check for the PHP Phar extension
    if ! php -m | grep -qi 'phar'; then
        echo "Dependency missing: The 'phar' PHP extension is required."
        read -p "Would you like to attempt to install php83-phar now? (y/n): " choice
        if [[ "$choice" == "y" ]]; then
            echo "Installing php83-phar..."
            if ! sudo apk add php83-phar || ! php -m | grep -qi 'phar'; then
                echo "Error: Installation failed. Please install 'php83-phar' manually and try again." >&2
                exit 1
            fi
            echo "Success: php83-phar has been installed."
        else
            echo "Installation declined. The script cannot continue." >&2
            exit 1
        fi
    fi
    
    # Check for the PHP JSON extension
    if ! php -m | grep -qi 'json'; then
        echo "Dependency missing: The 'json' PHP extension is recommended for WP-CLI."
        read -p "Would you like to attempt to install php83-json now? (y/n): " choice
        if [[ "$choice" == "y" ]]; then
            echo "Installing php83-json..."
            sudo apk add php83-json
            echo "Success: php83-json has been installed."
        fi
    fi

    # Check for the WP-CLI command
    if ! command -v wp &> /dev/null; then
        echo "Dependency missing: WP-CLI is not installed."
        read -p "Would you like to attempt to install WP-CLI now? (y/n): " choice
        if [[ "$choice" == "y" ]]; then
            echo "Downloading WP-CLI..."
            curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
            if [ ! -f "wp-cli.phar" ]; then
                echo "Error: Download failed. Please try installing WP-CLI manually." >&2
                exit 1
            fi
            echo "Installing WP-CLI to /usr/local/bin/wp..."
            chmod +x wp-cli.phar
            mv wp-cli.phar /usr/local/bin/wp
            if ! command -v wp &> /dev/null; then
                echo "Error: Installation failed. Please install WP-CLI manually." >&2
                exit 1
            fi
            echo "Success: WP-CLI has been installed."
        else
            echo "Installation declined. The script cannot continue." >&2
            exit 1
        fi
    fi
    echo "--- All required dependencies are satisfied ---"
    echo ""
}

# Flushes the WordPress internal caches using WP-CLI.
purge_wordpress_cache() {
    echo "Telling WordPress to flush its internal caches..."
    sudo -u "${WP_USER}" -- wp cache flush --path="${WP_PATH}"
    if [ $? -ne 0 ]; then
        echo "Warning: WP-CLI command failed. Please check permissions and configuration." >&2
    fi
}

# Restarts the Nginx service.
restart_nginx() {
    echo "Restarting Nginx to apply changes and ensure stability..."
    service nginx restart
    if [ $? -eq 0 ]; then
        echo "Success: Nginx was restarted."
    else
        echo "Error: Nginx failed to restart. Please check the Nginx error logs." >&2
    fi
}

# --- SCRIPT LOGIC ---

# Check if the script is run as root first.
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Please use 'sudo'." >&2
   exit 1
fi

# Run dependency checks.
check_and_install_dependencies

echo "Select an option:"
echo "1. Clear cache for a single URL"
echo "2. Clear the entire cache (will restart Nginx)"
read -p "Enter your choice (1 or 2): " choice

case $choice in
    1)
        read -p "Enter the full URL to clear: " URL
        if [[ "$URL" != "https://"* ]]; then
            echo "Error: The URL must start with 'https://'." >&2; exit 1;
        fi

        SCHEME="https"
        HOST=$(echo "$URL" | cut -d'/' -f3)
        REQUEST_URI="${URL#*$HOST}"; REQUEST_URI=${REQUEST_URI:-/}
        CACHE_KEY="${SCHEME}GET${HOST}${REQUEST_URI}"
        MD5_HASH=$(echo -n "$CACHE_KEY" | md5sum | awk '{print $1}')
        CACHE_FILE_PATH="${CACHE_PATH}/${MD5_HASH: -1:1}/${MD5_HASH: -3:2}/${MD5_HASH}"

        echo "----------------------------------------"
        if [ -f "$CACHE_FILE_PATH" ]; then
            echo "Step 1: Removing Nginx cache file..."
            rm -f "$CACHE_FILE_PATH"
            echo "Success: Nginx cache file removed."
            echo "Step 2: Syncing application state..."
            purge_wordpress_cache
        else
            echo "Notice: Nginx cache file not found. No action taken."
        fi
        echo "----------------------------------------"
        ;;
    2)
        read -p "This will delete all Nginx cache files, flush WordPress, AND restart Nginx. Are you sure? (yes/no): " confirm
        if [[ "$confirm" == "yes" ]]; then
            echo "Step 1: Clearing all Nginx cache files..."
            rm -rf "${CACHE_PATH}"/*
            echo "Success: Nginx cache directory cleared."
            echo "Step 2: Syncing application state..."
            purge_wordpress_cache
            echo "Step 3: Finalizing with Nginx restart..."
            restart_nginx
        else
            echo "Operation cancelled."
        fi
        ;;
    *)
        echo "Invalid choice. Please enter 1 or 2." >&2; exit 1;
        ;;
esac
