#!/usr/bin/env bash
# create_pod.sh
# =================================================================
# Distrobox Pod Creation Script
# Copyright (c) 2024-2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
# =================================================================
# This script creates and configures a new Distrobox pod with a choice of operating systems
# (AlmaLinux, Arch Linux, Debian, Kali Linux, or Ubuntu). It automates the installation
# of a set of useful packages and tools, including fastfetch, to provide a consistent
# and ready-to-use environment.
#
# Features:
# - Interactive OS selection menu.
# - Customizable pod name with a default option.
# - Automated package installation based on the selected OS.
# - Installation of the latest fastfetch release.
# - Support for command-line arguments to bypass the interactive menu.
#
# Usage:
# - Interactive mode: ./create_pod.sh
# - Non-interactive mode: ./create_pod.sh [os] [pod_name]
#
# Examples:
# - ./create_pod.sh
# - ./create_pod.sh archlinux my-arch-pod
# - ./create_pod.sh ubuntu
#
# Dependencies:
# - distrobox
# - wget
# - jq
# - curl
# =================================================================

set -o errexit -o nounset -o pipefail

# --- Configuration ---
readonly SUPPORTED_OS=(
  "AlmaLinux"
  "Arch Linux"
  "Debian"
  "Kali Linux"
  "Ubuntu"
)

# --- Helper Functions ---

# Log a message to the console.
#
# Args:
#   $1: The message to log.
log() {
  echo "INFO: $1"
}

# Log an error message and exit.
#
# Args:
#   $1: The error message.
error() {
  echo "ERROR: $1" >&2
  exit 1
}

# Check if a command exists.
#
# Args:
#   $1: The command to check.
command_exists() {
  command -v "$1" &>/dev/null
}

# --- Core Functions ---

# Check for required dependencies.
check_dependencies() {
  log "Checking for required dependencies..."
  local dependencies=("distrobox" "wget" "jq" "curl")
  for dep in "${dependencies[@]}"; do
    if ! command_exists "$dep"; then
      error "Dependency '$dep' is not installed. Please install it and try again."
    fi
  done
}

# Display the OS selection menu and get the user's choice.
#
# Returns:
#   The selected operating system.
select_os() {
  echo "Please select an operating system:" >&2
  select os in "${SUPPORTED_OS[@]}"; do
    if [[ -n "$os" ]]; then
      echo "$os"
      return
    else
      echo "Invalid selection. Please try again." >&2
    fi
  done
}

# Get the pod name from the user.
#
# Args:
#   $1: The default pod name.
#
# Returns:
#   The chosen pod name.
get_pod_name() {
  local default_name="${1:-}"
  local pod_name=""
  while true; do
    read -p "Enter the name for this pod (default: '$default_name'): " pod_name
    pod_name=${pod_name:-$default_name}
    if [[ -n "$pod_name" && "$pod_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      echo "$pod_name"
      return
    else
      echo "Invalid or empty pod name. Please use only letters, numbers, hyphens, underscores, and periods." >&2
    fi
  done
}

# Install fastfetch in the pod.
#
# Args:
#   $1: The pod name.
#   $2: The package type ('deb' or 'rpm').
install_fastfetch() {
  local pod_name="$1"
  local pkg_type="$2"
  log "Installing fastfetch for $pod_name..."

  local fastfetch_version
  fastfetch_version=$(curl -s https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest | jq -r '.tag_name')
  local download_url="https://github.com/fastfetch-cli/fastfetch/releases/download/$fastfetch_version/fastfetch-linux-amd64.$pkg_type"
  local file_name="fastfetch.$pkg_type"

  distrobox enter "$pod_name" -- wget -qO "$file_name" "$download_url"
  if [[ "$pkg_type" == "deb" ]]; then
    distrobox enter "$pod_name" -- sudo dpkg -i "$file_name"
  elif [[ "$pkg_type" == "rpm" ]]; then
    distrobox enter "$pod_name" -- sudo rpm -i "$file_name"
  fi
  distrobox enter "$pod_name" -- rm "$file_name"
}

# Create and configure the pod.
#
# Args:
#   $1: The operating system.
#   $2: The pod name.
create_pod() {
  local os_choice="$1"
  local pod_name="$2"
  local image_name
  local package_manager
  local packages
  local fastfetch_pkg_type=""

  case "$os_choice" in
    "AlmaLinux")
      image_name="almalinux"
      package_manager="dnf"
      packages="bat fish ugrep htop wget"
      fastfetch_pkg_type="rpm"
      ;;
    "Arch Linux")
      image_name="archlinux"
      package_manager="pacman"
      packages="bat fish ugrep eza htop wget ttf-hack-nerd fastfetch"
      ;;
    "Debian")
      image_name="debian"
      package_manager="apt"
      packages="bat fish ugrep eza htop wget fonts-hack"
      fastfetch_pkg_type="deb"
      ;;
    "Kali Linux")
      image_name="kali-rolling"
      package_manager="apt"
      packages="bat fish ugrep eza htop wget fonts-hack kali-linux-headless kali-linux-large"
      fastfetch_pkg_type="deb"
      ;;
    "Ubuntu")
      image_name="ubuntu"
      package_manager="apt"
      packages="bat fish ugrep eza htop wget fonts-hack"
      fastfetch_pkg_type="deb"
      ;;
    *)
      error "Unsupported OS: $os_choice"
      ;;
  esac

  log "Creating pod '$pod_name' with $os_choice..."
  distrobox create -i "${image_name}:latest" -n "$pod_name"

  log "Upgrading pod '$pod_name'..."
  distrobox upgrade "$pod_name"

  log "Installing packages in '$pod_name'..."
  if [[ "$package_manager" == "pacman" ]]; then
    distrobox enter "$pod_name" -- sudo pacman -Syu --noconfirm --needed $packages
    distrobox enter "$pod_name" -- sudo ln -sf /usr/bin/bat /usr/bin/batcat
  elif [[ "$package_manager" == "apt" ]]; then
    distrobox enter "$pod_name" -- sudo apt-get update
    distrobox enter "$pod_name" -- sudo apt-get install -y $packages
    distrobox enter "$pod_name" -- sudo ln -sf /usr/bin/batcat /usr/bin/bat
  elif [[ "$package_manager" == "dnf" ]]; then
    distrobox enter "$pod_name" -- sudo dnf -y install epel-release
    distrobox enter "$pod_name" -- sudo /usr/bin/crb enable
    distrobox enter "$pod_name" -- sudo dnf -y install $packages
    distrobox enter "$pod_name" -- sudo ln -sf /usr/bin/bat /usr/bin/batcat

    log "Installing eza for $pod_name..."
    local eza_url
    eza_url=$(curl -s https://api.github.com/repos/eza-community/eza/releases/latest | jq -r '.assets[] | select(.name | endswith("x86_64-unknown-linux-gnu.tar.gz")) | .browser_download_url')
    distrobox enter "$pod_name" -- sh -c " \
        mkdir eza-install && \
        cd eza-install && \
        wget -O eza.tar.gz '$eza_url' && \
        tar -xzf eza.tar.gz && \
        sudo mv eza /usr/local/bin/ && \
        cd .. && \
        rm -rf eza-install \
    "
  fi

  if [[ " ${packages} " =~ " fish " ]]; then
    log "Setting fish as the default shell for $pod_name..."
    distrobox enter "$pod_name" -- sh -c 'sudo usermod --shell /usr/bin/fish $USER'
  fi

  if [[ -n "$fastfetch_pkg_type" ]]; then
    install_fastfetch "$pod_name" "$fastfetch_pkg_type"
  fi

  log "Pod '$pod_name' has been successfully created and configured."
}

# --- Main Function ---
main() {
  check_dependencies

  local os
  local pod_name
  local default_pod_name

  if [[ $# -ge 1 ]]; then
    os_input=$(echo "$1" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1')
    if [[ " ${SUPPORTED_OS[*]} " =~ " ${os_input} " ]]; then
      os="$os_input"
    else
      # Check for case-insensitive partial match
      local match_count=0
      local matched_os=""
      for supported_os in "${SUPPORTED_OS[@]}"; do
        if [[ "${supported_os,,}" == *"${1,,}"* ]]; then
          match_count=$((match_count + 1))
          matched_os="$supported_os"
        fi
      done

      if [[ $match_count -eq 1 ]]; then
        os="$matched_os"
      else
        error "Unsupported or ambiguous OS: '$1'. Please choose from: ${SUPPORTED_OS[*]}"
      fi
    fi
  else
    os=$(select_os)
  fi

  default_pod_name=$(echo "$os" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

  if [[ $# -ge 2 ]]; then
    pod_name="$2"
  else
    pod_name=$(get_pod_name "$default_pod_name")
  fi

  create_pod "$os" "$pod_name"
}

# --- Script Execution ---
main "$@"