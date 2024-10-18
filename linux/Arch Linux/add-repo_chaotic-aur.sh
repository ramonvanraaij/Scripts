#!/bin/sh

# Copyright (c) 2024 Rámon van Raaij

# License: MIT

# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu

# add-repo_chaotic-aur.sh - This script adds the Chaotic AUR repository to Arch Linux. It downloads and verifies the key, updates the keyring, adds the repository to /etc/pacman.conf, and updates package lists.

# **Note:**
# Using AUR (Arch User Repository) packages can be riskier than official packages
# as they are not officially maintained. Ensure you trust the source of any package
# before installing it from the AUR.

# Add Chaotic AUR repository

# Add Chaotic AUR key
echo "Adding Chaotic AUR key..."
sudo pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
sudo pacman-key --lsign-key 3056513887B78AEB

# Update keyring
echo "Updating keyring..."
sudo pacman -Sy chaotic-aur

# Add Chaotic AUR repository to /etc/pacman.conf
echo "Adding Chaotic AUR repository to /etc/pacman.conf..."
sudo tee -a /etc/pacman.conf << EOF
[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
EOF

# Update package lists
echo "Updating package lists..."
sudo pacman -Syu

