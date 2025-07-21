#!/bin/bash

# Copyright (c) 2024 Rámon van Raaij

# License: MIT

# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu

# install_Snap_Store.sh - This script installs snapd, apparmor, squashfs-tools and the Snap Store  on Arch Linux.
# It installs yay if needed and creates a symlink to /var/lib/snapd/snap for classic snap support.

# Check if yay is installed
if ! command -v yay &> /dev/null; then
  echo "yay is not installed."

  # Check if yay is available in the repositories
  if pacman -Ss yay &> /dev/null; then
    echo "yay is available in the repositories. Installing..."
    sudo pacman -S --noconfirm yay
  else
    echo "yay is not available in the repositories. Installing from AUR..."

    # Install required packages (without confirmation)
    sudo pacman -S --needed git base-devel --noconfirm

    # Create temporary directory if it doesn't exist
    mkdir -p /tmp

    # Clone yay from AUR, build, and install
    pushd /tmp > /dev/null # Save current directory and change to /tmp
    git clone https://aur.archlinux.org/yay.git
    pushd yay > /dev/null
    makepkg -si --noconfirm # Use --noconfirm here as well
    popd > /dev/null
    rm -rf yay
    popd > /dev/null # Restore original directory

  fi
  echo "yay installation complete."
fi

# Check if /snap symlink already exists
if [ ! -L /snap ]; then
  echo "/snap symlink does not exist. Installing snapd and creating symlink..."
  # Install snapd and apparmor
  yay -S --noconfirm snapd apparmor squashfs-tools

  # Create /snap directory if it doesn't exist
  sudo mkdir -p /var/lib/snapd/snap

  # Enable classic snap support
  sudo ln -s /var/lib/snapd/snap /snap

  # Enable and start apparmor systemd unit
  sudo systemctl enable --now snapd.apparmor.service
  sleep 5 # Sleep time, might not be necessary at all

  # Enable and start snapd systemd unit
  sudo systemctl enable --now snapd.socket
  sleep 15 # Sleep time, might not be necessary at all
  echo "waiting 15 seconds for snap to get ready..."

else
  echo "/snap symlink already exists. Skipping snapd installation and symlink creation."
fi

# Install Snap Store
sudo snap install snap-store

echo "Script execution complete."
