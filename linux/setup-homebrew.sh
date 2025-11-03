#!/usr/bin/env bash
# setup-homebrew.sh
# =================================================================
# Title: Homebrew for Linux Installer
#
# Copyright (c) 2024-2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script automates the installation of Homebrew on Linux.
# It installs the necessary dependencies for Debian/Ubuntu and Arch-based
# distributions, then downloads and runs the official Homebrew installation script.
# Finally, it configures the user's shell environment.
#
# It performs the following actions:
# 1. Checks for non-interactive mode.
# 2. Installs required dependencies (build-essential for Debian, base-devel for Arch).
# 3. Downloads and runs the official Homebrew installer.
# 4. Configures the shell environment (bash, zsh, fish) for future sessions.
#
# **Note:**
# This script requires sudo privileges to install system packages.
# =================================================================

# --- Sanity checks ---
set -o errexit -o nounset -o pipefail

# --- Configuration ---
NONINTERACTIVE=false
if [[ "${1-}" == "-y" ]] || [[ "${1-}" == "--yes" ]]; then
  NONINTERACTIVE=true
fi

# --- Functions ---
log_message() {
  echo "=> $1"
}

install_dependencies() {
  log_message "Installing dependencies..."
  if ! command -v sudo &> /dev/null; then
    log_message "sudo command not found. Please install sudo."
    exit 1
  fi
  
  if command -v pacman &> /dev/null; then
    sudo pacman -S --needed --noconfirm base-devel git
  elif command -v apt-get &> /dev/null; then
    sudo apt-get update
    sudo apt-get install -y build-essential procps curl file git
  else
    log_message "Unsupported package manager. Please install build tools and git manually."
    # We can still try to proceed, Homebrew installer will check for git.
  fi
}

install_homebrew() {
  log_message "Installing Homebrew..."
  if $NONINTERACTIVE; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" < /dev/null
  else
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
}

configure_shell() {
  log_message "Configuring shell..."
  local brew_dir="/home/linuxbrew/.linuxbrew"
  local brew_exe="${brew_dir}/bin/brew"

  if [ ! -f "$brew_exe" ]; then
      log_message "Homebrew executable not found at $brew_exe. Cannot configure shell."
      log_message "Please add the output of 'brew shellenv' to your shell configuration file."
      return
  fi

  local shell_config_file
  case "$SHELL" in
    /bin/bash) shell_config_file="$HOME/.bashrc" ;; 
    /bin/zsh) shell_config_file="$HOME/.zshrc" ;; 
    /bin/fish) shell_config_file="$HOME/.config/fish/config.fish" ;; 
    *) 
      log_message "Unsupported shell: $SHELL. Please configure your shell manually."
      log_message "Add the output of the following command to your shell's startup file:"
      "$brew_exe" shellenv
      return
      ;; 
  esac

  mkdir -p "$(dirname "$shell_config_file")"
  touch "$shell_config_file"

  if grep -q "brew shellenv" "$shell_config_file"; then
      log_message "Homebrew already configured in $shell_config_file."
  else
      log_message "Adding Homebrew configuration to $shell_config_file."
      if [[ "$SHELL" == "/bin/fish" ]]; then
          cat <<EOF >> "$shell_config_file"

# Homebrew
if test -d $brew_dir
    $brew_exe shellenv | source
end
EOF
      else
          cat <<EOF >> "$shell_config_file"

# Homebrew
if [ -d "$brew_dir" ]; then
    eval "$("$brew_exe" shellenv)"
fi
EOF
      fi
  fi
}

# --- Main ---
main() {
  if ! $NONINTERACTIVE; then
    read -p "This script will install Homebrew and its dependencies. Do you want to proceed? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_message "Exiting."
      exit 0
    fi
  fi

  install_dependencies
  install_homebrew
  configure_shell

  log_message "Homebrew installation complete."
  log_message "Please open a new terminal or source your shell configuration file (e.g., source ~/.bashrc)."
  log_message "Then, run 'brew doctor' to verify your installation."
}

main "$@"