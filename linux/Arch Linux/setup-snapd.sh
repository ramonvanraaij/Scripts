#!/usr/bin/env bash
# setup-snapd.sh
# =================================================================
# Snapd and Snap Store Installer for Arch Linux
#
# Copyright (c) 2024-2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script automates the installation and configuration of Snapd on Arch Linux.
# It ensures that 'yay' is installed, then installs 'snapd', 'apparmor', and 'squashfs-tools'.
# The script also enables classic snap support by creating a symbolic link from /snap
# to /var/lib/snapd/snap. Finally, it installs the Snap Store.
#
# It performs the following actions:
# 1. Automatically installs 'yay' if it is not found.
# 2. Installs Snapd, AppArmor, and required tools.
# 3. Enables and starts necessary systemd services.
# 4. Enables classic snap support.
# 5. Installs the Snap Store.
#
# **Note:**
# Snapd is not officially supported by Arch Linux and may introduce
# compatibility issues. Use with caution.
# =================================================================

# --- Sanity checks ---
# Exit immediately if a command exits with a non-zero status.
set -o errexit
# Treat unset variables as an error when substituting.
set -o nounset
# Pipelines return the exit status of the last command that failed.
set -o pipefail

# --- Dependency Check: yay ---
# Check if yay is installed and install it if not.
if ! command -v yay &> /dev/null; then
  echo "yay is not installed. Proceeding with installation."

  # Check if yay is available in a configured repository
  if pacman -Sp yay &> /dev/null; then
    echo "yay is available in the repositories. Installing with pacman..."
    sudo pacman -S --noconfirm yay
  else
    echo "yay is not available in the repositories. Building from AUR..."

    # Install build dependencies
    sudo pacman -S --needed --noconfirm git base-devel

    # Create a temporary directory for the build
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT

    # Clone, build, and install yay
    git clone https://aur.archlinux.org/yay.git "$temp_dir"
    (cd "$temp_dir" && makepkg -si --noconfirm)

  fi
  echo "yay installation complete."
else
  echo "yay is already installed."
fi

# --- Snapd Installation and Configuration ---
# Check if the /snap symlink exists to prevent re-installation.
if [ ! -L /snap ]; then
  echo "/snap symlink does not exist. Installing snapd..."

  # Install build dependencies to ensure 'patch' and other tools are available
  sudo pacman -S --needed --noconfirm base-devel

  # Install snapd, apparmor, and squashfs-tools using yay
  yay -S --noconfirm snapd apparmor squashfs-tools

  # Enable classic snap support by creating the required symlink
  sudo ln -s /var/lib/snapd/snap /snap

  # Enable and start the AppArmor service for Snapd
  echo "Enabling and starting AppArmor service for Snapd..."
  sudo systemctl enable --now snapd.apparmor.service

  # Enable and start the Snapd socket
  echo "Enabling and starting Snapd socket..."
  sudo systemctl enable --now snapd.socket

  # Wait for the snapd socket to be ready
  echo "Waiting for snapd to become ready..."
  sleep 15

  echo "Snapd installation and configuration complete."
else
  echo "/snap symlink already exists. Skipping snapd installation."
fi

# --- Snap Store Installation ---
echo "Installing the Snap Store..."
sudo snap install snap-store

echo "Script execution complete."