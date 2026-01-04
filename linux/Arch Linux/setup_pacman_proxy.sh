#!/usr/bin/env bash
# setup_pacman_proxy.sh
# =================================================================
# Secure Caching Pacman & AUR Proxy Server Setup
#
# Copyright (c) 2026 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script automates the installation and configuration of a complete
# Arch Linux package caching solution using pacoloco and nginx. It is
# designed to be run on a dedicated Arch Linux server to provide a
# fast, local package proxy for other machines on the network.
#
# It performs the following actions:
# 1. Installs dependencies: pacoloco, nginx, reflector, apache-tools.
# 2. Prompts for user-specific settings (port, username, password).
# 3. Optimizes mirror lists for Arch and Chaotic-AUR using reflector.
# 4. Configures pacoloco to cache packages for specified repositories,
#    keeping the last 2 versions and prefetching updates.
# 5. Configures nginx as a secure reverse proxy with HTTP Basic Auth.
# 6. Sets up a daily cron job to automatically update the server and
#    reboot only when the network is idle.
# 7. Enables and starts all required services.
# 8. Displays clear instructions for configuring client machines.
#
# Usage:
# 1. Make the script executable:
#    chmod +x setup_pacman_proxy.sh
# 2. Run the script with root privileges on your server:
#    sudo ./setup_pacman_proxy.sh
#
# **Note:**
# This script is intended for a fresh Arch Linux server. It will
# overwrite existing configurations for nginx (/etc/nginx/nginx.conf)
# and pacoloco (/etc/pacoloco.conf).
# =================================================================

set -euo pipefail

# --- Global Variables ---
NGINX_PORT=""
PROXY_USER=""
PROXY_PASS=""
HTPASSWD_FILE="/etc/nginx/.htpasswd"

# --- Functions ---

# Function to ensure the script is run as root
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: This script must be run as root."
        echo "Please use 'sudo ./setup_pacman_proxy.sh'"
        exit 1
    fi
}

# Function to get configuration details from the user
get_user_input() {
    echo "--- Server Configuration ---"
    
    # Get port for nginx
    while true; do
        read -rp "Enter the public port for the nginx proxy (e.g., 8129): " NGINX_PORT
        if [[ "${NGINX_PORT}" =~ ^[0-9]+$ ]] && [ "${NGINX_PORT}" -gt 1024 ] && [ "${NGINX_PORT}" -lt 65536 ]; then
            break
        else
            echo "Invalid port. Please enter a number between 1025 and 65535."
        fi
    done

    # Get username for proxy authentication
    read -rp "Enter the username for proxy access: " PROXY_USER
    if [[ -z "${PROXY_USER}" ]]; then
        echo "Username cannot be empty."
        exit 1
    fi

    # Get password for proxy authentication
    read -rp "Enter the password for '${PROXY_USER}': " PROXY_PASS
    echo
    if [[ -z "${PROXY_PASS}" ]]; then
        echo "Password cannot be empty."
        exit 1
    fi
}

# Function to bootstrap a working pacman mirrorlist
bootstrap_pacman() {
    echo "--- Bootstrapping Pacman with a valid mirrorlist ---"
    # Backup the original mirrorlist, if it exists
    if [[ -f /etc/pacman.d/mirrorlist ]]; then
        cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.orig.bak
    fi

    # Download a fresh, comprehensive list of mirrors from the Arch Linux website
    curl -o /etc/pacman.d/mirrorlist 'https://archlinux.org/mirrorlist/all/'

    # Uncomment all servers in the new mirrorlist to ensure pacman can connect
    sed -i 's/^#Server/Server/' /etc/pacman.d/mirrorlist

    echo "Pacman bootstrap complete. A temporary mirrorlist is active."
}

# Function to install necessary packages
install_dependencies() {
    echo "--- Installing Dependencies ---"
    # Create an empty chaotic-mirrorlist to prevent pacman from failing if the repo is in pacman.conf
    # but the file doesn't exist yet.
    touch /etc/pacman.d/chaotic-mirrorlist
    pacman -Syu --noconfirm --needed pacoloco nginx reflector apache cronie
    echo "Dependencies installed successfully."
}

# Function to set up Chaotic-AUR repository on the server
setup_chaotic_aur_repo() {
    echo "--- Setting up Chaotic-AUR Repository ---"

    echo "Importing Chaotic-AUR PGP key..."
    sudo pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com || true # Use true to prevent script exiting if keyserver is temporarily unavailable
    sudo pacman-key --lsign-key 3056513887B78AEB

    echo "Installing chaotic-keyring and chaotic-mirrorlist..."
    sudo pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
    sudo pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'

        # Handle the .pacnew file created by the installation

        if [[ -f /etc/pacman.d/chaotic-mirrorlist.pacnew ]]; then

            mv /etc/pacman.d/chaotic-mirrorlist.pacnew /etc/pacman.d/chaotic-mirrorlist

        fi

    

        echo "Chaotic-AUR repository setup complete."

    }

# Function to configure reflector to get the best mirrors
configure_reflector() {
    echo "--- Optimizing Core Arch Linux Mirror List with Reflector ---"
    
    # The main mirrorlist was backed up during bootstrap, so we just optimize it here.
    if ! reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist; then
        echo "ERROR: reflector failed to generate a mirrorlist. Using the fallback."
        cp /etc/pacman.d/mirrorlist.orig.bak /etc/pacman.d/mirrorlist
    fi
    
    # Remove trailing slashes from the mirrorlist URLs
    sed -i 's#/$##' /etc/pacman.d/mirrorlist
    
    echo "Core Arch Linux mirror list updated successfully."
}

# Function to configure pacoloco
configure_pacoloco() {
    echo "--- Configuring Pacoloco ---"
    
    # Create pacoloco YAML config
    cat <<EOF > /etc/pacoloco.yaml
# Pacoloco configuration file generated by setup_pacman_proxy.sh
# For details, see https://github.com/anatol/pacoloco
port: 9129
purge_files_after: 2419200 # 28 days in seconds
download_timeout: 180
keep_last_n_versions: 2

# Prefetching settings
prefetch:
  # Check for updates every day at 4 AM
  cron: '0 0 4 * * * *'
  # Stop prefetching packages that haven't been downloaded in 30 days
  ttl_unaccessed_in_days: 30

# Repository definitions
repos:
  # A single logical repo for all official Arch repositories
  archlinux:
    mirrorlist: /etc/pacman.d/mirrorlist

  # Repo for Chaotic-AUR - using a direct URL template is more reliable
  chaotic-aur:
    urls:
      - https://aur.chaotic.cx/chaotic-aur

  # LizardByte Repos (fixed URL)
  lizardbyte:
    url: https://github.com/LizardByte/pacman-repo/releases/latest/download
  
  lizardbyte-beta:
    url: https://github.com/LizardByte/pacman-repo/releases/download/beta

  # Garuda repo - also uses a direct URL template
  garuda:
    urls:
      - https://aur.chaotic.cx/garuda

EOF
    echo "Pacoloco configuration written to /etc/pacoloco.yaml."
}

# Function to configure nginx as a secure reverse proxy
configure_nginx() {
    echo "--- Configuring Nginx Secure Reverse Proxy ---"

    # Create htpasswd file for basic auth
    echo "Creating user '${PROXY_USER}' for proxy authentication..."
    htpasswd -cb "${HTPASSWD_FILE}" "${PROXY_USER}" "${PROXY_PASS}"
    chmod 644 "${HTPASSWD_FILE}"
    echo "Authentication file created at ${HTPASSWD_FILE}."

    # Create nginx cache directory
    mkdir -p /var/cache/nginx/proxy_cache
    chown http:http /var/cache/nginx/proxy_cache

    # Overwrite nginx configuration
    cat <<EOF > /etc/nginx/nginx.conf
# Nginx configuration generated by setup_pacman_proxy.sh
# It sets up a secure, caching reverse proxy for pacoloco.

user http;
worker_processes auto;
pid /var/run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
}

http {
    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;
    error_log   /var/log/nginx/error.log;

    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;

    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;
    
    # --- Cache Configuration ---
    # This cache is for general purpose use (e.g., yay source downloads)
    proxy_cache_path /var/cache/nginx/proxy_cache levels=1:2 keys_zone=aur_cache:10m max_size=5g inactive=60d use_temp_path=off;

    # --- Server Block ---
    server {
        listen ${NGINX_PORT};
        server_name _; # Listen for any hostname

        # --- Security: HTTP Basic Authentication ---
        auth_basic "Private Pacman Proxy";
        auth_basic_user_file ${HTPASSWD_FILE};

        # --- Caching ---
        proxy_cache aur_cache;
        proxy_cache_valid 200 302 7d;
        proxy_cache_valid 404 1m;

        # --- Location for database files (NO CACHING) ---
        location ~ \.db(\.sig)?$ {
            # Never cache database files as they change frequently
            proxy_no_cache 1;
            proxy_cache_bypass 1;

            proxy_pass http://127.0.0.1:9129;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
        
        # --- Location Block for Proxying to Pacoloco ---
        location / {
            proxy_buffering off;
            proxy_hide_header Content-Length;
            proxy_pass http://127.0.0.1:9129;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
}
EOF
    echo "Nginx configuration written to /etc/nginx/nginx.conf."
    
    # Test nginx configuration
    nginx -t
}

# Function to enable and start services
enable_services() {
    echo "--- Enabling and Starting Services ---"
    systemctl enable pacoloco.service
    systemctl start pacoloco.service
    
    systemctl enable nginx.service
    systemctl start nginx.service
    
    systemctl enable --now cronie.service
    
    echo "Pacoloco, Nginx, and Cronie services have been enabled and started."
    systemctl status pacoloco.service --no-pager
    systemctl status nginx.service --no-pager
    systemctl status cronie.service --no-pager
}

# Function to configure automatic daily updates and reboots
configure_autoupdate() {
    echo "--- Configuring Automatic Daily Updates ---"

    # Create the daily update script
    cat <<'EOF' > /usr/local/bin/daily-update.sh
#!/usr/bin/env bash
# daily-update.sh
# This script updates the system and reboots it if the network is idle.

set -euo pipefail

LOG_FILE="/var/log/daily-update.log"
BPS_THRESHOLD=10240 # 10 KB/s threshold for network traffic
MAX_RETRIES=5
RETRY_INTERVAL_MIN=3 # In minutes

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "${LOG_FILE}"
}

get_bytes() {
    local interface
    interface=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
    if [[ -z "$interface" ]]; then
        log "ERROR: Could not determine default network interface."
        exit 1
    fi
    # Sum of received and transmitted bytes
    awk '{s+=$1} END {print s}' "/sys/class/net/${interface}/statistics/rx_bytes" "/sys/class/net/${interface}/statistics/tx_bytes"
}

log "--- Starting daily system update ---"
pacman -Syu --noconfirm
log "System update complete."

for (( i=1; i<=MAX_RETRIES; i++ )); do
    log "Performing network idle check (Attempt ${i}/${MAX_RETRIES})..."
    
    bytes_before=$(get_bytes)
    sleep 5
    bytes_after=$(get_bytes)
    
    # Calculate bytes per second
    bps=$(( (bytes_after - bytes_before) / 5 ))
    
    log "Current network traffic: ${bps} B/s."
    
    if (( bps < BPS_THRESHOLD )); then
        log "Network is idle (traffic is below ${BPS_THRESHOLD} B/s). Rebooting now."
        # Use 'nohup' to ensure the reboot command is not terminated if the script's shell is killed
        nohup reboot &
        exit 0
    else
        log "Network is busy. Deferring reboot check."
        if (( i < MAX_RETRIES )); then
            log "Will try again in ${RETRY_INTERVAL_MIN} minutes."
            sleep $((RETRY_INTERVAL_MIN * 60))
        fi
    fi
done

log "--- Daily update finished. Reboot aborted as system remained busy. ---"
EOF

    chmod +x /usr/local/bin/daily-update.sh
    echo "Update script created at /usr/local/bin/daily-update.sh."

    # Create the cron job
    cat <<EOF > /etc/cron.d/autoupdate
# Cron job for daily system updates and conditional reboots
SHELL=/bin/bash
PATH=/sbin:/bin:/usr/sbin:/usr/bin

# Run daily at 3:30 AM, with a random delay up to 10 minutes
30 3 * * * root sleep \$((RANDOM \\% 600)) && /usr/local/bin/daily-update.sh
EOF
    
    echo "Cron job created at /etc/cron.d/autoupdate."
}

# Function to show client configuration instructions
show_client_instructions() {
    local server_ip
    server_ip=$(ip addr | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -n1)

    echo "================================================================="
    echo "✅ Pacman Proxy Server Setup Complete!"
    echo "================================================================="
    echo
    echo "Your proxy is running at: http://${server_ip}:${NGINX_PORT}"
    echo "Username: ${PROXY_USER}"
    echo "Password (visible for client setup): ${PROXY_PASS}"
    echo
    echo "AUTOMATIC UPDATES: This server is now configured to auto-update"
    echo "and reboot daily between 4:00 and 4:01 AM if network is idle."
    echo "Logs are available at /var/log/daily-update.log"
    echo
    echo "To use this proxy on your client machines, edit /etc/pacman.conf"
    echo "and replace the content of your repository sections as follows:"
    echo
    echo "--------------------- /etc/pacman.conf (Client Example) ----------------------"
    echo "#"
    echo "# REPOSITORIES"
    echo "# - lines starting with a '#' are commented out"
    echo "# - you can add your own servers here, but they will be used only if"
    echo "#   all servers defined in the mirrorlist are not reachable"
    echo "#"
    
    echo "[options]"
    echo "HoldPkg     = pacman glibc"
    echo "Architecture = auto"
    echo "Color"
    echo "CheckSpace"
    echo "VerbosePkgLists"
    echo "ParallelDownloads = 5"
    echo
    echo "SigLevel    = Required DatabaseOptional"
    echo "LocalFileSigLevel = Optional"
    echo
    
    echo "# --- Official Repositories (via pacoloco proxy) ---"
    echo "# The '\$repo' variable is filled in by pacman."
    echo "[core]"
    echo "Server = http://${PROXY_USER}:${PROXY_PASS}@${server_ip}:${NGINX_PORT}/repo/archlinux/\$repo/os/\$arch"
    echo
    echo "[extra]"
    echo "Server = http://${PROXY_USER}:${PROXY_PASS}@${server_ip}:${NGINX_PORT}/repo/archlinux/\$repo/os/\$arch"
    echo
    echo "[multilib]"
    echo "Server = http://${PROXY_USER}:${PROXY_PASS}@${server_ip}:${NGINX_PORT}/repo/archlinux/\$repo/os/\$arch"
    echo
    
    echo "# --- Chaotic AUR (via pacoloco proxy) ---"
    echo "[chaotic-aur]"
    echo "Server = http://${PROXY_USER}:${PROXY_PASS}@${server_ip}:${NGINX_PORT}/repo/chaotic-aur/\\\$arch"
    echo
    
    echo "# --- Garuda (via pacoloco proxy) ---"
    echo "[garuda]"
    echo "Server = http://${PROXY_USER}:${PROXY_PASS}@${server_ip}:${NGINX_PORT}/repo/garuda/\\\$arch"
    echo
    
    echo "# --- LizardByte Repos (via pacoloco proxy) ---"
    echo "[lizardbyte]"
    echo "SigLevel = Optional"
    echo "Server = http://${PROXY_USER}:${PROXY_PASS}@${server_ip}:${NGINX_PORT}/repo/lizardbyte"
    echo
    echo "[lizardbyte-beta]"
    echo "SigLevel = Optional"
    echo "Server = http://${PROXY_USER}:${PROXY_PASS}@${server_ip}:${NGINX_PORT}/repo/lizardbyte-beta"
    echo "--------------------------------------------------------------------------"
    echo
    echo "**IMPORTANT:** Remember to replace '${server_ip}' with your server's public IP"
    echo "or domain name if you are accessing it from the internet."
    echo "If you have a firewall, ensure port ${NGINX_PORT} is open."
}

# --- Main Execution ---
main() {
    check_root
    bootstrap_pacman
    get_user_input
    install_dependencies
    setup_chaotic_aur_repo
    configure_reflector
    configure_pacoloco
    configure_nginx
    enable_services
    configure_autoupdate
    show_client_instructions
}

main
