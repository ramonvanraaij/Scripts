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
 # and ready-to-use environment. It also allows the user to specify whether to use
 # an init system inside the container, which can prevent host processes from being
 # visible within the container.
 #
 # Features:
 # - Interactive OS selection menu.
 # - Customizable pod name with a default option.
 # - Option to use an init system inside the container (`--init` flag for distrobox).
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
 # - ./create_pod.sh ubuntu#
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
  "Alpine Linux"
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

# Get the pod name and init system preference from the user.
#
# Args:
#   $1: The default pod name.
#
# Returns:
#   A string containing the chosen pod name and a boolean (true/false) for init system preference, separated by a space.
get_pod_details() {
  local default_name="${1:-}"

  while true; do
    read -r -p "Enter the name for this pod (default: '$default_name'): " POD_NAME
    POD_NAME=${POD_NAME:-$default_name}
    if [[ -n "$POD_NAME" && "$POD_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      break
    else
      echo "Invalid or empty pod name. Please use only letters, numbers, hyphens, underscores, and periods." >&2
    fi
  done

  read -p "Use init system inside the container? (y/N): " -n 1 -r
  echo
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    USE_INIT="true"
  else
    USE_INIT="false"
  fi
}

# Install bashtop from source.
#
# Args:
#   $1: The pod name.
install_bashtop_from_source() {
  local pod_name="$1"
  log "Installing bashtop from source for $pod_name..."
  distrobox enter "$pod_name" -- sh -c " \
      git clone https://github.com/aristocratos/bashtop.git && \
      cd bashtop && \
      sudo make install && \
      cd .. && \
      rm -rf bashtop \
  "
}

# Install bashtop for Ubuntu.
#
# Args:
#   $1: The pod name.
install_bashtop_ubuntu() {
  local pod_name="$1"
  log "Installing bashtop for Ubuntu..."
  distrobox enter "$pod_name" -- sh -c " \
      sudo apt-get install -y software-properties-common && \
      sudo add-apt-repository -y ppa:bashtop-monitor/bashtop && \
      sudo apt-get update && \
      sudo apt-get install -y bashtop \
  "
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
#   $3: Boolean indicating whether to use init system (true/false).
create_pod() {
  local os_choice="$1"
  local pod_name="$2"
  local use_init="$3"
  local image_name
  local package_manager
  local packages
  local fastfetch_pkg_type=""

  case "$os_choice" in
    "AlmaLinux")
      image_name="almalinux"
      package_manager="dnf"
      packages="bat fish ugrep htop wget fastfetch git make util-linux-user"
      fastfetch_pkg_type="rpm"
      ;;
    "Alpine Linux")
      image_name="alpine"
      package_manager="apk"
      packages="bat fish ugrep eza htop wget fastfetch git make"
      ;;
    "Arch Linux")
      image_name="archlinux"
      package_manager="pacman"
      packages="bat fish ugrep eza htop bashtop wget ttf-hack-nerd fastfetch git make"
      ;;
    "Debian")
      image_name="debian"
      package_manager="apt"
      packages="bat fish ugrep eza htop wget fonts-hack git make bashtop"
      fastfetch_pkg_type="deb"
      ;;
    "Kali Linux")
      image_name="kali-rolling"
      package_manager="apt"
      packages="bat fish ugrep eza htop wget fonts-hack kali-linux-headless kali-linux-large git make bashtop"
      fastfetch_pkg_type="deb"
      ;;
    "Ubuntu")
      image_name="ubuntu"
      package_manager="apt"
      packages="bat fish ugrep eza htop wget fonts-hack git make"
      fastfetch_pkg_type="deb"
      ;;
    *)
      error "Unsupported OS: $os_choice"
      ;;
  esac

  log "Creating pod '$pod_name' with $os_choice..."
  local init_flag=""
  if [[ "$use_init" == "true" ]]; then
    init_flag="--init"
  fi
  distrobox create -i "${image_name}:latest" -n "$pod_name" $init_flag

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
    distrobox enter "$pod_name" -- sudo dnf -y update
    distrobox enter "$pod_name" -- sudo dnf -y install $packages
    distrobox enter "$pod_name" -- sudo ln -sf /usr/bin/bat /usr/bin/batcat

    log "Installing eza for $pod_name..."
    local eza_url
    eza_url=$(curl -s https://api.github.com/repos/eza-community/eza/releases/latest | jq -r '.assets[] | select(.name | endswith("x86_64-unknown-linux-gnu.tar.gz")) | .browser_download_url')
    distrobox enter "$pod_name" -- sh -c " \
        rm -rf eza-install && \
        mkdir eza-install && \
        cd eza-install && \
        wget -O eza.tar.gz '$eza_url' && \
        tar -xzf eza.tar.gz && \
        sudo mv eza /usr/local/bin/ && \
        cd .. && \
        rm -rf eza-install && \
        sudo ln -sf /usr/local/bin/eza /usr/local/bin/exa \
    "
  elif [[ "$package_manager" == "apk" ]]; then
    distrobox enter "$pod_name" -- sudo apk update
    distrobox enter "$pod_name" -- sudo apk add $packages
    distrobox enter "$pod_name" -- sudo ln -sf /usr/bin/batcat /usr/bin/bat
  fi

  if [[ ! " ${packages} " =~ " bashtop " ]]; then
    if [[ "$os_choice" == "Ubuntu" ]]; then
      install_bashtop_ubuntu "$pod_name"
    else
      install_bashtop_from_source "$pod_name"
    fi
  fi

  if [[ " ${packages} " =~ " fish " ]]; then
    log "Setting fish as the default shell for $pod_name..."
    distrobox enter "$pod_name" -- sh -c 'sudo chsh -s /usr/bin/fish $USER'
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
    if [[ " ${SUPPORTED_OS[*]} " =~ ${os_input} ]]; then
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
    POD_NAME="$2"
    USE_INIT="false"
  else
    get_pod_details "$default_pod_name"
  fi

  create_pod "$os" "$POD_NAME" "$USE_INIT"
}

# --- Script Execution ---
main "$@"
