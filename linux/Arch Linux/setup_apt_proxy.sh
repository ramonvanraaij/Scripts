#!/usr/bin/env bash
# setup_apt_proxy.sh
# =================================================================
# Debian/Ubuntu Apt-Cacher-NG Proxy Setup (Add-on)
#
# Copyright (c) 2026 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# **IMPORTANT:**
# This script is an ADDITION to setup_pacman_proxy.sh.
# It is designed to be run on the same Arch Linux server AFTER
# the main pacman proxy setup has been completed.
#
# It performs the following actions:
# 1. Installs apt-cacher-ng using pacman.
# 2. Enables and starts the apt-cacher-ng service.
# 3. Injects a secure /apt/ location block into the existing
#    Nginx configuration (managed by the pacman proxy script).
# 4. Validates the configuration and functionality.
#
# Usage:
#    sudo ./setup_apt_proxy.sh
#
#    To skip the interactive credential prompt for validation:
#    sudo PROXY_USER=admin PROXY_PASS=secret ./setup_apt_proxy.sh
# =================================================================

set -euo pipefail

NGINX_CONF="/etc/nginx/nginx.conf"
PROXY_USER="${PROXY_USER:-}"
PROXY_PASS="${PROXY_PASS:-}"

# --- Functions ---

# Function to ensure the script is run as root
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: This script must be run as root."
        exit 1
    fi
}

# Function to check if Nginx is installed and configured
check_dependencies() {
    if ! command -v nginx &> /dev/null; then
        echo "ERROR: Nginx is not installed. Run setup_pacman_proxy.sh first."
        exit 1
    fi
    if [[ ! -f "$NGINX_CONF" ]]; then
        echo "ERROR: Nginx configuration not found at $NGINX_CONF."
        exit 1
    fi
}

# Function to enable Chaotic-AUR if not already present
enable_chaotic_aur() {
    echo "--- Enabling Chaotic-AUR ---"
    
    if grep -q "^\[chaotic-aur\]" /etc/pacman.conf; then
        echo "Chaotic-AUR is already configured in /etc/pacman.conf."
    else
        echo "Importing keys and installing keyring/mirrorlist..."
        pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
        pacman-key --lsign-key 3056513887B78AEB
        
        pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
        pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'

        echo "Appending [chaotic-aur] to /etc/pacman.conf..."
        cat <<EOF >> /etc/pacman.conf

[chaotic-aur]
# Use local pacoloco cache first
Server = http://127.0.0.1:9129/repo/chaotic-aur/\$arch
Include = /etc/pacman.d/chaotic-mirrorlist
EOF
        echo "Chaotic-AUR enabled."
    fi
    
    echo "Refreshing package databases..."
    pacman -Sy
}

# Function to install apt-cacher-ng via AUR (using yay)
install_apt_cacher_ng() {
    echo "--- Installing Apt-Cacher-NG ---"
    
    # Check if apt-cacher-ng is already installed
    if pacman -Qi apt-cacher-ng >/dev/null 2>&1; then
        echo "apt-cacher-ng is already installed."
    else
        echo "Installing yay..."
        pacman -S --noconfirm --needed yay base-devel

        echo "Installing apt-cacher-ng using yay..."
        
        # Create builder user if it doesn't exist
        if ! id -u builder >/dev/null 2>&1; then
            useradd -m builder
            echo "builder ALL=(ALL) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/builder
        fi
        
        # Run yay as builder
        sudo -u builder yay -S --noconfirm apt-cacher-ng

        echo "Cleaning up builder user..."
        rm -f /etc/sudoers.d/builder
        userdel -r builder
    fi
    
    echo "Configuring backends..."
    # Ensure backend files exist in /etc/apt-cacher-ng/ with correct paths
    # The default might be missing the /debian suffix
    echo "http://ftp.debian.org/debian/" > /etc/apt-cacher-ng/backends_debian
    
    if [[ ! -f /etc/apt-cacher-ng/backends_ubuntu ]]; then
        cp /usr/lib/apt-cacher-ng/backends_ubuntu.default /etc/apt-cacher-ng/backends_ubuntu || true
    fi

    echo "Starting apt-cacher-ng service..."
    systemctl enable --now apt-cacher-ng
    # Restart to pick up backend changes
    systemctl restart apt-cacher-ng
    
    # Wait a moment for the service to bind to the port
    sleep 2
    if ! systemctl is-active --quiet apt-cacher-ng; then
        echo "ERROR: apt-cacher-ng failed to start."
        systemctl status apt-cacher-ng --no-pager
        exit 1
    fi
    echo "Apt-Cacher-NG is running."
}

# Function to configure apt-cacher-ng settings (expiration, etc.)
configure_acng() {
    echo "--- Configuring Apt-Cacher-NG Settings ---"
    local ACNG_CONF="/etc/apt-cacher-ng/acng.conf"
    
    # Backup config
    cp "$ACNG_CONF" "${ACNG_CONF}.bak"
    
    # Set ExThreshold to 28 days
    sed -i 's/^#\?\s*ExThreshold:.*/ExThreshold: 28/' "$ACNG_CONF"
    
    # Keep extra versions (approximate "keep last 2 versions")
    sed -i 's/^#\?\s*KeepExtraVersions:.*/KeepExtraVersions: 1/' "$ACNG_CONF"
    
    # Restart to apply
    systemctl restart apt-cacher-ng
    echo "Apt-Cacher-NG settings updated."
}

# Function to inject the /apt/ location block into Nginx configuration
inject_nginx_config() {
    echo "--- Configuring Nginx ---"
    
    if grep -q "location /apt/" "$NGINX_CONF"; then
        echo "Configuration already contains '/apt/' location. Skipping injection."
        return
    fi

    echo "Injecting /apt/ location block into $NGINX_CONF..."

    # Create the block content in a temp file
    cat <<'EOF' > /tmp/nginx_apt_block.txt

        # --- Apt-Cacher-NG Proxy ---
        location /apt/ {
            # Trailing slash is CRITICAL to strip '/apt/' before sending to backend
            proxy_pass http://127.0.0.1:3142/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            
            # Reuse existing authentication
            auth_basic "Private Repo Proxy";
            auth_basic_user_file /etc/nginx/.htpasswd;
        }

EOF

    # Use Perl to insert the file content BEFORE the 'location /pacman/ {' line
    # This avoids sed escaping issues.
    perl -i -pe 'BEGIN{undef $/;} s/(location \/pacman\/ \{)/`cat \/tmp\/nginx_apt_block.txt` . $1/e' "$NGINX_CONF"
    
    rm /tmp/nginx_apt_block.txt
    echo "Injection complete."
}

# Function to validate and restart Nginx
validate_config() {
    echo "--- Validating Nginx Configuration ---"
    if ! nginx -t; then
        echo "ERROR: Nginx configuration test failed. Restoring might be necessary."
        exit 1
    fi
    
    echo "Restarting Nginx..."
    systemctl restart nginx
}

# Function to test the proxy connection
test_proxy() {
    echo "--- Testing Proxy Functionality ---"
    
    # Prompt for credentials if not provided
    if [[ -z "${PROXY_USER}" ]]; then
        read -rp "Enter Proxy Username (used in setup_pacman_proxy.sh): " PROXY_USER
    fi
    
    if [[ -z "${PROXY_PASS}" ]]; then
        read -rp "Enter Proxy Password: " -s PROXY_PASS
        echo
    fi

    echo "Testing connection to internal apt-cacher-ng via Nginx..."
    
    # We test against the internal report page to verify the proxy and auth are working.
    TEST_URL="http://127.0.0.1/apt/acng-report.html"
    
    # We use -o /dev/null to discard output, -w to get http code, -f to fail on error
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "${PROXY_USER}:${PROXY_PASS}" "${TEST_URL}" || true)

    if [[ "$HTTP_CODE" == "200" ]]; then
        echo "✅ SUCCESS: Proxy returned HTTP 200 for $TEST_URL"
    else
        echo "❌ FAILURE: Proxy returned HTTP $HTTP_CODE for $TEST_URL"
        echo "Please check logs: journalctl -u nginx -u apt-cacher-ng"
        exit 1
    fi
}

# Function to display client configuration instructions
show_client_instructions() {
    local server_ip
    server_ip=$(ip addr | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -n1)
    # Default port from setup_pacman_proxy.sh if not set
    local port="${NGINX_PORT:-80}"

    echo "================================================================="
    echo "✅ Apt-Cacher-NG Proxy Setup Complete!"
    echo "================================================================="
    echo
    echo "Your Apt proxy is running at: http://${server_ip}:${port}/apt/"
    echo "Username: ${PROXY_USER:-<your_username>}"
    echo "Password: ${PROXY_PASS:-<your_password>}"
    echo
    echo "To use this proxy securely on your Debian/Ubuntu client machines:"
    echo
    echo "1. Configure authentication in /etc/apt/auth.conf:"
    echo "   (Create the file if it doesn't exist, and make it readable only by root)"
    echo "   -----------------------------------------------------------------"
    echo "   machine http://${server_ip} login ${PROXY_USER:-user} password ${PROXY_PASS:-pass}"
    echo "   -----------------------------------------------------------------"
    echo "   Command: echo 'machine http://${server_ip} login ${PROXY_USER:-user} password ${PROXY_PASS:-pass}' | sudo tee -a /etc/apt/auth.conf > /dev/null && sudo chmod 600 /etc/apt/auth.conf"
    echo
    echo "2. Edit your /etc/apt/sources.list to point to the proxy (without credentials):"
    echo "   -----------------------------------------------------------------"
    echo "   # Main Debian Repo"
    echo "   deb http://${server_ip}:${port}/apt/debian stable main"
    echo
    echo "   # Security Updates"
    echo "   deb http://${server_ip}:${port}/apt/debian-security stable-security main"
    echo
    echo "   # Updates"
    echo "   deb http://${server_ip}:${port}/apt/debian stable-updates main"
    echo "   -----------------------------------------------------------------"
    echo
    echo "**IMPORTANT:** Remember to replace '${server_ip}' with your server's public IP"
    echo "or domain name if you are accessing it from the internet."
}

# --- Main ---
main() {
    check_root
    check_dependencies
    enable_chaotic_aur
    install_apt_cacher_ng
    configure_acng
    inject_nginx_config
    validate_config
    test_proxy
    show_client_instructions
}
main
