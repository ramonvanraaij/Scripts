#!/usr/bin/env bash
# upgrade_npm_trixie.sh
# =================================================================
# Nginx Proxy Manager Upgrade & Repair Script (Debian Bookworm -> Trixie)
#
# Copyright (c) 2024-2026 Rámon van Raaij
# License: BSD-3-Clause
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script automates the repair and upgrade of Nginx Proxy Manager
# on a Debian system that has been (or will be) upgraded to Debian Trixie.
#
# This LXC container is assumed to have been created with the Proxmox VE
# Community Script: https://community-scripts.github.io/ProxmoxVE/scripts?id=nginxproxymanager
#
# The decision to perform an in-place upgrade rather than a fresh install
# was motivated by the fact that NPM lacks a native import/export function.
#
# It performs the following actions:
# 1. Checks for root privileges.
# 2. Optionally upgrades Debian from Bookworm to Trixie.
# 3. Installs build dependencies for OpenResty (system PCRE2).
# 4. Recreates the Certbot Python virtual environment (Python 3.13 fix).
# 5. Compiles OpenResty 1.29.2.5 against the system PCRE2 library.
# 6. Upgrades Node.js to the system version (v20+).
# 7. Downloads, patches, and deploys the NPM source code (v2.15.1).
# 8. Sets CERTBOT_VERSION for the NPM service (2.15.x plugin pinning fix).
# 9. Adds the $x_forwarded_scheme / $x_forwarded_proto nginx maps (2.15.x).
# 10. Fixes Nginx service conflicts (killing rogue processes).
# 11. Restarts services and verifies status.
#
# Usage:
#   chmod +x upgrade_npm_trixie.sh
#   sudo ./upgrade_npm_trixie.sh
#
# **Note:**
# Ensure you have a full backup (e.g., via Proxmox Backup Server) before running.
# =================================================================

# Strict mode
set -o errexit -o nounset -o pipefail

# --- Configuration ---
readonly OPENRESTY_VERSION="1.29.2.5"
readonly NPM_TAG="v2.15.1"
readonly APP_DIR="/app"
# Declare then assign separately so the command substitution's exit status is not
# masked by 'readonly' (shellcheck SC2155).
BACKUP_DIR="/app_backup_$(date +%Y%m%d_%H%M%S)"
readonly BACKUP_DIR
# --- End Configuration ---

# --- Functions ---
log() {
    printf "\e[32m[INFO]\e[0m %s\n" "$1"
}

error() {
    printf "\e[31m[ERROR]\e[0m %s\n" "$1" >&2
    exit 1
}
# --- End Functions ---

# --- Core Functions ---
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "This script must be run as root. Please use 'sudo'."
    fi
}

upgrade_debian() {
    log "Checking Debian version..."
    if grep -q "bookworm" /etc/os-release; then
        printf "Current system appears to be Bookworm. Upgrade to Trixie now? (y/n): "
        read -r reply
        if [ "$reply" = "y" ] || [ "$reply" = "Y" ]; then
            log "Updating APT sources to trixie..."
            # Handle both classic sources.list and DEB822 format (.sources)
            sed -i 's/bookworm/trixie/g' /etc/apt/sources.list 2>/dev/null || true
            find /etc/apt/sources.list.d/ -name '*.sources' -exec sed -i 's/bookworm/trixie/g' {} + 2>/dev/null || true
            find /etc/apt/sources.list.d/ -name '*.list' -exec sed -i 's/bookworm/trixie/g' {} + 2>/dev/null || true
            log "Running update and full-upgrade..."
            apt-get update
            apt-get full-upgrade -y
            log "Upgrade complete. A reboot is highly recommended."
            log "Note: rebooting now exits this script; re-run it after the reboot to continue."
            printf "Reboot now? (y/n): "
            read -r reply
            if [ "$reply" = "y" ] || [ "$reply" = "Y" ]; then
                reboot
            else
                log "Continuing without reboot (Risky)..."
            fi
        else
            log "Skipping OS upgrade."
        fi
    else
        log "System does not appear to be Bookworm or already upgraded."
    fi
}

install_dependencies() {
    log "Installing build dependencies..."
    apt-get update
    # Added psmisc for killall command needed in fix_nginx_service
    apt-get install -y build-essential libpcre2-dev libssl-dev zlib1g-dev wget curl git python3-venv python3-pip python3-dev psmisc lsof
}

fix_certbot() {
    log "Recreating Certbot virtual environment (Python 3.13 fix)..."
    [ -d "/opt/certbot" ] && rm -rf /opt/certbot
    python3 -m venv /opt/certbot
    /opt/certbot/bin/pip install --upgrade pip
    /opt/certbot/bin/pip install certbot certbot-dns-cloudflare
    ln -sf /opt/certbot/bin/certbot /usr/bin/certbot
}

compile_openresty() {
    log "Compiling OpenResty ${OPENRESTY_VERSION}..."
    
    # Ensure ldconfig path for LuaJIT
    export PATH="$PATH:/sbin:/usr/sbin"

    local WORK_DIR
    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "${WORK_DIR}"' RETURN
    cd "${WORK_DIR}"

    log "Fetching OpenResty source..."
    wget -q "https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz"
    tar -xzf "openresty-${OPENRESTY_VERSION}.tar.gz"
    cd "openresty-${OPENRESTY_VERSION}"

    # Trixie ships PCRE2 (libpcre2-dev). Modern Nginx/OpenResty auto-detects it,
    # so no legacy PCRE source build or --with-pcre=<path> is needed anymore.
    log "Configuring OpenResty against system PCRE2..."
    ./configure \
        --with-pcre-jit \
        --with-http_ssl_module \
        --with-http_stub_status_module \
        --with-http_realip_module \
        --with-http_auth_request_module \
        --with-http_v2_module \
        --with-http_dav_module \
        --with-http_slice_module \
        --with-threads \
        --with-http_addition_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_sub_module \
        --with-stream \
        --with-stream_ssl_module \
        --with-stream_ssl_preread_module

    make -j"$(nproc)"
    make install
}

upgrade_nodejs() {
    log "Upgrading Node.js to system version..."
    apt-get install -y nodejs npm
    rm -f /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx
    ln -sf /usr/bin/node /usr/local/bin/node
    ln -sf /usr/bin/npm /usr/local/bin/npm
}

deploy_npm() {
    log "Backing up installation to ${BACKUP_DIR}..."
    cp -ra "${APP_DIR}" "${BACKUP_DIR}"

    local WORK_DIR
    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "${WORK_DIR}"' RETURN
    cd "${WORK_DIR}"

    log "Downloading NPM ${NPM_TAG}..."
    wget -q -O npm.tar.gz "https://github.com/NginxProxyManager/nginx-proxy-manager/archive/refs/tags/${NPM_TAG}.tar.gz"
    tar -xzf npm.tar.gz
    cd "nginx-proxy-manager-${NPM_TAG#v}"

    # NPM 2.15.x dropped the root package.json and ships only frontend/backend ones,
    # so patch whichever placeholder files actually exist (a missing file would abort
    # the script under 'set -o errexit').
    log "Patching version numbers..."
    for pj in package.json frontend/package.json backend/package.json; do
        [ -f "${pj}" ] && sed -i "s/\"version\": \"2.0.0\"/\"version\": \"${NPM_TAG#v}\"/" "${pj}"
    done

    log "Building Frontend..."
    (cd frontend && npm install && npm run locale-compile && npm run build)

    log "Deploying Files..."
    systemctl stop npm || true
    cp "${APP_DIR}/config/production.json" "${WORK_DIR}/production.json.bak"
    find "${APP_DIR}" -mindepth 1 ! -regex "^${APP_DIR}/config\(/.*\)?$" -delete
    cp -a backend/. "${APP_DIR}/"
    mv "${WORK_DIR}/production.json.bak" "${APP_DIR}/config/production.json"
    mkdir -p "${APP_DIR}/frontend"
    cp -a frontend/dist/. "${APP_DIR}/frontend/"

    log "Deploying default Nginx configuration..."
    mkdir -p /usr/local/openresty/nginx/conf/conf.d
    cp -r docker/rootfs/etc/nginx/conf.d/include /usr/local/openresty/nginx/conf/conf.d/

    log "Installing Backend Dependencies..."
    cd "${APP_DIR}"
    npm install --production
}

set_certbot_version_env() {
    # NPM 2.15.x (lib/certbot.js) pins the certbot plugin / acme versions from the
    # $CERTBOT_VERSION env var. The Docker image sets it; this non-Docker install does
    # not, so plugin install builds 'acme==undefined', fails, and the backend
    # crash-loops on startup. Set it from the installed certbot via a systemd drop-in.
    log "Setting CERTBOT_VERSION for the NPM service (NPM 2.15.x)..."
    local cbver
    # certbot prints "certbot X.Y.Z"; match that exact line (and exit) so a stray
    # warning/deprecation line folded in by 2>&1 cannot produce a multi-line value.
    # Assign inside the 'if' so a failed certbot run gives our message rather than an
    # opaque 'set -e' abort on the command substitution.
    if ! cbver=$(/opt/certbot/bin/certbot --version 2>&1 | awk '/^certbot /{print $2; exit}'); then
        error "Failed to run /opt/certbot/bin/certbot to determine its version."
    fi
    if ! printf '%s' "${cbver}" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
        error "Could not determine certbot version (got: '${cbver}')."
    fi
    mkdir -p /etc/systemd/system/npm.service.d
    cat > /etc/systemd/system/npm.service.d/certbot-version.conf <<EOF
[Service]
Environment=CERTBOT_VERSION=${cbver}
EOF
    systemctl daemon-reload
}

add_forwarded_maps() {
    # NPM 2.15.x vhost templates reference $x_forwarded_scheme / $x_forwarded_proto.
    # Their 'map' definitions ship in the Docker image's nginx.conf, which this install
    # does not use, so reloads fail with 'unknown "x_forwarded_scheme" variable'. Define
    # them at http context via a conf.d drop-in loaded by 'include /etc/nginx/conf.d/*.conf;'
    # (i.e. /usr/local/openresty/nginx/conf.d, reached through the /etc/nginx symlink).
    log "Adding X-Forwarded-* nginx maps (NPM 2.15.x)..."
    local confd="/usr/local/openresty/nginx/conf.d"
    mkdir -p "${confd}"
    cat > "${confd}/x-forwarded-maps.conf" <<'MAPEOF'
map $http_x_forwarded_proto $x_forwarded_proto {
    "http"  "http";
    "https" "https";
    default $scheme;
}
map $http_x_forwarded_scheme $x_forwarded_scheme {
    "http"  "http";
    "https" "https";
    default $scheme;
}
MAPEOF
}

fix_nginx_service() {
    log "Fixing Nginx service conflicts..."
    
    # Check if port 80 is occupied by an old nginx process
    if lsof -i :80 2>/dev/null | grep -q nginx; then
        log "Found old Nginx process holding port 80. Killing it..."
        killall nginx || true
        sleep 2
    fi

    log "Validating OpenResty configuration..."
    /usr/local/openresty/nginx/sbin/nginx -t
    log "Restarting OpenResty service..."
    systemctl restart openresty
}

main() {
    check_root
    upgrade_debian
    install_dependencies
    fix_certbot
    compile_openresty
    upgrade_nodejs
    deploy_npm
    set_certbot_version_env
    add_forwarded_maps
    fix_nginx_service
    
    log "Restarting Backend Service..."
    systemctl restart npm
    
    log "Upgrade complete. Verified on port 81."
}
# --- End Core Functions ---

# --- Script execution ---
main "$@"
# --- End Script execution ---