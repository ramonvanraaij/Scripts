#!/usr/bin/env sh
# clear_nginx_cache.sh
# =================================================================
# NGINX Cache Management Tool
#
# Copyright (c) 2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
# =================================================================
# This script automates the process of managing the NGINX cache for
# a WordPress site. It supports both interactive and non-interactive
# (command-line flag) operation.
#
# It performs the following actions:
# 1. Detects the OS (Alpine, Debian, Ubuntu, CentOS, RHEL, etc.).
# 2. Checks for required dependencies like `curl` and WP-CLI and can
#    offer to install them.
# 3. Flushes the NGINX cache for a single URL or the entire cache directory.
# 4. Flushes the WordPress internal object cache.
# 5. For full cache clearing, it also safely restarts the NGINX service.
#
# --- Setup ---
# 1. Configuration: Edit the variables in the "Configuration" section below.
# 2. Permissions: Make the script executable:
#    chmod +x clear_nginx_cache.sh
#
# --- Usage ---
# Run the script with sudo.
#
#   For an interactive menu, run the script without any flags:
#   sudo ./clear_nginx_cache.sh
#
#   For non-interactive use (e.g., in scripts), use flags:
#   - To clear the cache for a single URL:
#     sudo ./clear_nginx_cache.sh -u https://example.com/some-page/
#
#   - To clear the entire cache (with a confirmation prompt):
#     sudo ./clear_nginx_cache.sh -a
#
#   - To clear the entire cache WITHOUT a confirmation prompt:
#     sudo ./clear_nginx_cache.sh -a -y
# =================================================================

# --- Script Configuration ---
# Exit on error, treat unset variables as an error, and fail on piped command errors.
set -o errexit -o nounset -o pipefail

# --- Configuration ---
readonly CACHE_PATH="/var/cache/nginx/example-site"
readonly WP_PATH="/var/www/example.com/public_html"
readonly WP_USER="www-data" # The system user that owns the WordPress files

# --- Global Variables ---
OS_FAMILY=""
PKG_MANAGER=""
PHP_PHAR_PKG=""
PHP_JSON_PKG=""

# --- Core Functions ---

# Logs a message to the console with a timestamp.
log_message() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

# Displays the script's usage information for flag errors.
usage() {
    echo "Usage: $0 [-u URL] [-a [-y]]"
    echo "  Run without arguments for an interactive menu."
    echo "  -u <URL>  Clear the cache for a single URL."
    echo "  -a        Clear the entire cache."
    echo "  -y        Proceed without confirmation (only with -a)."
    exit 1
}

# Detects the operating system and sets the appropriate package manager.
detect_os() {
    log_message "Detecting operating system..."
    if ! [ -f /etc/os-release ]; then
        log_message "FATAL: Cannot detect OS because /etc/os-release is not present." >&2
        exit 1
    fi

    # Source the os-release file to get OS info
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_FAMILY=${ID}

    case "${OS_FAMILY}" in
        alpine)
            PKG_MANAGER="apk add"
            PHP_PHAR_PKG="php-phar"
            PHP_JSON_PKG="php-json"
            ;;
        debian|ubuntu)
            PKG_MANAGER="apt-get install -y"
            PHP_PHAR_PKG="php-phar"
            PHP_JSON_PKG="php-json"
            ;;
        centos|rhel|rocky|almalinux)
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf install -y"
            else
                PKG_MANAGER="yum install -y"
            fi
            PHP_PHAR_PKG="php-phar"
            PHP_JSON_PKG="php-json"
            ;;
        *)
            log_message "FATAL: Unsupported operating system detected: '${OS_FAMILY}'." >&2
            exit 1
            ;;
    esac
    log_message "System detected as '${OS_FAMILY}'. Using '${PKG_MANAGER}' for package installation."
}

# Installs a package using the detected package manager.
install_package() {
    local package_name="$1"
    log_message "Attempting to install '${package_name}'..."
    # We are splitting PKG_MANAGER intentionally.
    # shellcheck disable=SC2086
    if ! sudo ${PKG_MANAGER} "${package_name}"; then
        log_message "ERROR: Installation failed. Please install '${package_name}' manually." >&2
        exit 1
    fi
    log_message "Success: ${package_name} has been installed."
}

# Checks for a command and offers to install its package if missing.
check_and_install() {
    local command_name="$1"
    local package_name="$2"
    local description="$3"

    if ! command -v "${command_name}" >/dev/null 2>&1; then
        log_message "Dependency missing: ${description}"
        read -p "Would you like to attempt to install '${package_name}' now? (y/n): " choice
        if [ "${choice}" = "y" ]; then
            install_package "${package_name}"
        else
            log_message "Installation declined. The script cannot continue without '${package_name}'." >&2
            exit 1
        fi
    fi
}

# Checks if a PHP extension is loaded.
is_php_ext_loaded() {
    php -m | grep -qi "$1"
}

# Checks for a PHP extension and offers to install it if missing.
check_and_install_php_ext() {
    local ext_name="$1"
    local package_name="$2"
    local is_required="$3"

    if ! is_php_ext_loaded "${ext_name}"; then
        local required_text="is required"
        if [ "$is_required" != "true" ]; then
            required_text="is recommended"
        fi
        log_message "PHP extension missing: The '${ext_name}' extension ${required_text} for WP-CLI."
        read -p "Would you like to attempt to install '${package_name}' now? (y/n): " choice
        if [ "${choice}" = "y" ]; then
            install_package "${package_name}"
            # Verify it's loaded after installation attempt
            if ! is_php_ext_loaded "${ext_name}"; then
                log_message "ERROR: PHP extension '${ext_name}' still not loaded after installation." >&2
                if [ "$is_required" = "true" ]; then exit 1; fi
            fi
        elif [ "$is_required" = "true" ]; then
            log_message "Installation declined. Script cannot continue." >&2
            exit 1
        fi
    fi
}

# --- Task-specific Functions ---

# Purges the Nginx and WordPress cache for a single URL.
purge_single_url() {
    local url_to_clear="$1"
    # Validate the URL format.
    if ! echo "${url_to_clear}" | grep -qE '^https?://'; then
        log_message "ERROR: The URL must start with 'http://' or 'https://'." >&2
        exit 1
    fi

    # Deconstruct URL to build the Nginx cache key
    local scheme
    scheme=$(echo "${url_to_clear}" | grep -o 'https\?://' | sed 's/:\/\///')
    local host
    host=$(echo "${url_to_clear}" | sed -e 's,^https\?://,,' -e 's,/.*$,,')
    
    local request_uri
    request_uri="${url_to_clear#*//${host}}"
    request_uri=${request_uri:-/} # Ensure homepage is "/"
    
    local cache_key="${scheme}GET${host}${request_uri}"
    local md5_hash
    md5_hash=$(echo -n "${cache_key}" | md5sum | awk '{print $1}')
    
    # Use awk for portable substring extraction, required for BusyBox compatibility.
    local last_char
    last_char=$(echo "${md5_hash}" | awk '{print substr($0, length($0), 1)}')
    local second_to_last_two
    second_to_last_two=$(echo "${md5_hash}" | awk '{print substr($0, length($0)-2, 2)}')
    local cache_file_path="${CACHE_PATH}/${last_char}/${second_to_last_two}/${md5_hash}"

    log_message "--- Clearing cache for ${url_to_clear} ---"
    if [ -f "${cache_file_path}" ]; then
        log_message "Step 1: Removing Nginx cache file: ${cache_file_path}"
        rm -f "${cache_file_path}"
        log_message "Success: Nginx cache file removed."
        log_message "Step 2: Flushing WordPress object cache..."
        purge_wordpress_cache
    else
        log_message "Notice: Nginx cache file not found at expected path. No action taken."
    fi
    log_message "--- Operation complete ---"
}

# Purges the entire Nginx and WordPress cache.
purge_all_cache() {
    local auto_confirm="$1"
    local confirm=""
    
    if [ "${auto_confirm}" = "false" ]; then
        read -p "This will DELETE ALL files in '${CACHE_PATH}', flush WordPress, and RESTART Nginx. Are you sure? (yes/no): " confirm
    fi

    # Proceed if confirmed or if auto-confirm is enabled.
    if [ "${confirm}" = "yes" ] || [ "${auto_confirm}" = "true" ]; then
        log_message "--- Clearing entire Nginx cache ---"
        if [ -d "${CACHE_PATH}" ]; then
            log_message "Step 1: Clearing all Nginx cache files..."
            # Safer than 'rm -rf *'
            find "${CACHE_PATH}" -mindepth 1 -delete
            log_message "Success: Nginx cache directory cleared."
        else
            log_message "WARNING: Cache path '${CACHE_PATH}' does not exist. Skipping."
        fi
        
        log_message "Step 2: Flushing WordPress object cache..."
        purge_wordpress_cache
        
        log_message "Step 3: Restarting Nginx..."
        restart_nginx
        log_message "--- Operation complete ---"
    else
        log_message "Operation cancelled."
    fi
}

# Flushes the WordPress internal caches using WP-CLI.
purge_wordpress_cache() {
    log_message "Flushing WordPress internal object cache..."
    # Use a non-critical approach; cache flush can fail if no object cache is configured.
    if ! sudo -u "${WP_USER}" -- wp cache flush --path="${WP_PATH}"; then
        log_message "WARNING: 'wp cache flush' failed. This is often safe if no persistent object cache is used."
    fi
}

# Restarts the Nginx service using the appropriate command.
restart_nginx() {
    log_message "Restarting Nginx service..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart nginx
    elif command -v service >/dev/null 2>&1; then
        service nginx restart
    else
        log_message "ERROR: Could not find 'systemctl' or 'service' to restart Nginx." >&2
        return 1
    fi
    log_message "Success: Nginx restart command issued."
}

# Checks for all required tools and offers to install them if missing.
run_dependency_checks() {
    log_message "--- Checking for required dependencies ---"
    detect_os
    check_and_install "curl" "curl" "'curl' is required to download WP-CLI."
    check_and_install_php_ext "phar" "${PHP_PHAR_PKG}" "true"
    check_and_install_php_ext "json" "${PHP_JSON_PKG}" "false"

    if ! command -v wp >/dev/null 2>&1; then
        log_message "Dependency missing: WP-CLI is not installed."
        read -p "Would you like to attempt to install WP-CLI now? (y/n): " choice
        if [ "${choice}" = "y" ]; then
            log_message "Downloading WP-CLI..."
            curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
            chmod +x wp-cli.phar
            sudo mv wp-cli.phar /usr/local/bin/wp
            if ! command -v wp >/dev/null 2>&1; then
                log_message "ERROR: WP-CLI installation failed. Please install it manually." >&2
                exit 1
            fi
            log_message "Success: WP-CLI has been installed to /usr/local/bin/wp."
        else
            log_message "Installation declined. The script cannot continue." >&2
            exit 1
        fi
    fi
    log_message "--- All required dependencies are satisfied ---"
}


# --- Main Script Logic ---
main() {
    # --- 1. Pre-flight Checks ---
    if [ "$(id -u)" -ne 0 ]; then
        log_message "FATAL: This script must be run as root. Please use 'sudo'." >&2
        exit 1
    fi

    # --- 2. Determine Mode (Interactive vs. Flags) ---
    if [ $# -eq 0 ]; then
        # --- Interactive Mode ---
        echo "NGINX Cache Management Tool"
        echo "---------------------------"
        echo "1. Clear cache for a single URL"
        echo "2. Clear the ENTIRE cache (will restart Nginx)"
        read -p "Enter your choice (1 or 2): " choice

        # Dependency checks are only run if an action is to be performed.
        run_dependency_checks

        case ${choice} in
            1)
                read -p "Enter the full URL to clear: " url_input
                purge_single_url "$url_input"
                ;;
            2)
                # Always ask for confirmation in interactive mode.
                purge_all_cache "false" 
                ;;
            *)
                log_message "Invalid choice. Please enter 1 or 2." >&2; exit 1;
                ;;
        esac
    else
        # --- Non-Interactive (Flag) Mode ---
        local URL_TO_CLEAR=""
        local ACTION=""
        local AUTO_CONFIRM="false"
        
        while getopts "u:ay" opt; do
            case ${opt} in
                u)
                    ACTION="url"
                    URL_TO_CLEAR="${OPTARG}"
                    ;;
                a)
                    ACTION="all"
                    ;;
                y)
                    AUTO_CONFIRM="true"
                    ;;
                \?)
                    usage
                    ;;
            esac
        done

        # Validate that an action was specified.
        if [ -z "$ACTION" ]; then
            log_message "ERROR: No valid action flag specified." >&2
            usage
        fi
        
        run_dependency_checks
        
        if [ "$ACTION" = "url" ]; then
            purge_single_url "$URL_TO_CLEAR"
        elif [ "$ACTION" = "all" ]; then
            purge_all_cache "$AUTO_CONFIRM"
        fi
    fi
}

# Execute the main function, passing all command-line arguments to it.
main "$@"

