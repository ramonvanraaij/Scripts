#!/bin/bash
# configure_gzip.sh
# =================================================================
# NGINX Gzip Configuration Tool
# Copyright (c) 2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
# =================================================================
# This script automates the process of checking and enabling a
# recommended set of Gzip compression settings in an NGINX
# configuration file (/etc/nginx/nginx.conf).
#
# It performs the following actions:
# 1. Verifies it is run with root privileges.
# 2. Checks for the presence of specific Gzip directives.
# 3. Reports on which settings are found and which are missing.
# 4. If settings are missing, it prompts for confirmation before
#    proceeding.
# 5. Creates a timestamped backup of the current nginx.conf.
# 6. Inserts the missing Gzip settings into the http block.
# 7. Provides instructions for testing and reloading NGINX.
#
# Usage:
# 1. Make the script executable: chmod +x configure_gzip.sh
# 2. Run the script with sudo:   sudo ./configure_gzip.sh
# =================================================================

# --- Configuration ---
NGINX_CONF="/etc/nginx/nginx.conf"
declare -a GZIP_SETTINGS=(
    'gzip on;'
    'gzip_disable "msie6";'
    'gzip_vary on;'
    'gzip_proxied any;'
    'gzip_comp_level 6;'
    'gzip_buffers 16 8k;'
    'gzip_http_version 1.1;'
    'gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;'
)

# --- Colors for output ---
COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_RESET='\033[0m'

# --- Script Logic ---

# 1. Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo -e "${COLOR_RED}This script must be run as root. Please use 'sudo'.${COLOR_RESET}"
   exit 1
fi

# 2. Check if the NGINX configuration file exists
if [ ! -f "$NGINX_CONF" ]; then
    echo -e "${COLOR_RED}Error: NGINX config file not found at '$NGINX_CONF'.${COLOR_RESET}"
    exit 1
fi

echo "Checking Gzip settings in $NGINX_CONF..."
echo "--------------------------------------------------"

declare -a missing_settings=()

# 3. Check each setting and populate the missing_settings array
for setting in "${GZIP_SETTINGS[@]}"; do
    if grep -q "^\s*${setting}" "$NGINX_CONF"; then
        echo -e "[ ${COLOR_GREEN}Found${COLOR_RESET}   ] ${setting}"
    else
        echo -e "[ ${COLOR_RED}Missing${COLOR_RESET} ] ${setting}"
        missing_settings+=("$setting")
    fi
done

echo "--------------------------------------------------"

# 4. If all settings are found, exit
if [ ${#missing_settings[@]} -eq 0 ]; then
    echo -e "${COLOR_GREEN}Success: All recommended Gzip settings are already configured.${COLOR_RESET}"
    exit 0
fi

# 5. If settings are missing, prompt the user for action
echo -e "${COLOR_YELLOW}One or more Gzip settings are missing.${COLOR_RESET}"
read -p "Do you want to automatically add the missing settings now? (y/n): " -n 1 -r
echo # Move to a new line

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborting. No changes were made."
    exit 1
fi

# 6. Create a timestamped backup
BACKUP_FILE="${NGINX_CONF}.$(date +%F_%T).bak"
echo -e "\nCreating backup of current configuration at ${COLOR_YELLOW}${BACKUP_FILE}${COLOR_RESET}..."
cp "$NGINX_CONF" "$BACKUP_FILE"
if [ $? -ne 0 ]; then
    echo -e "${COLOR_RED}Error: Failed to create backup. Aborting to ensure safety.${COLOR_RESET}"
    exit 1
fi
echo -e "${COLOR_GREEN}Backup created successfully.${COLOR_RESET}"

# 7. Add the missing settings to the configuration file
echo "Applying changes to $NGINX_CONF..."

# Prepare a block of text with the missing settings
insertion_block="\n    # --- Gzip Settings (Added by script on $(date +%F)) ---\n"
for setting in "${missing_settings[@]}"; do
    insertion_block+="    ${setting}\n"
done
insertion_block+="    # --- End Gzip Settings ---\n"

# Find the line number of the last closing brace '}' in the file.
# This typically corresponds to the end of the http block.
last_brace_line=$(grep -n "^\s*}" "$NGINX_CONF" | tail -n 1 | cut -d: -f1)

if [ -z "$last_brace_line" ]; then
    echo -e "${COLOR_RED}Error: Could not automatically determine where to insert settings.${COLOR_RESET}"
    echo "Please add them manually. Your configuration was not changed."
    exit 1
fi

# Use a temporary file to robustly insert the multi-line block with sed
temp_file=$(mktemp)
echo -e "$insertion_block" > "$temp_file"
# The 'r' command reads the content of a file and inserts it after the specified line number.
# We target the line *before* the closing brace.
sed -i "$((last_brace_line - 1))r $temp_file" "$NGINX_CONF"
rm "$temp_file"

echo -e "${COLOR_GREEN}Configuration updated successfully!${COLOR_RESET}"
echo "--------------------------------------------------"
echo -e "${COLOR_YELLOW}IMPORTANT NEXT STEPS:${COLOR_RESET}"
echo "1. Test your NGINX configuration for syntax errors:"
echo -e "   ${COLOR_GREEN}sudo nginx -t${COLOR_RESET}"
echo
echo "2. If the test is successful, gracefully reload NGINX to apply changes:"
echo -e "   ${COLOR_GREEN}sudo systemctl reload nginx${COLOR_RESET}"

exit 0
