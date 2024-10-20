#!/bin/bash

# Copyright (c) 2024 Rámon van Raaij

# License: MIT

# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu

# install_qnap-qsync.sh - This script installs QNAP Qsync on Arch Linux. It installs debtap if needed, updates package lists, downloads the Qsync package, converts it to Arch format, installs it, cleans up, and provides confirmation.

# **Note:**
# This script relies on `debtap` for conversion, which might not guarantee perfect compatibility.

# Install debtap if not already installed
if ! pacman -Q debtap > /dev/null 2>&1; then
  echo "Installing debtap..."
  sudo pacman -S debtap
fi

# Update debtap package list
echo "Updating debtap..."
sudo debtap -u

# Download the latest Qsync package for Ubuntu (x64)
DOWNLOAD_URL=$(curl -sL https://update.qnap.com/SoftwareRelease.xml | xmllint --xpath '/docRoot/utility/application[applicationName="com.qnap.qsync"]/platform[platformName="Ubuntu"]/software/downloadURL' - | sed 's/<\/downloadURL>//; s/<downloadURL>//'| head -n 1)
DOWNLOAD_FILE="QNAPQsyncClientUbuntux64.deb"

wget -O "$DOWNLOAD_FILE" "$DOWNLOAD_URL"

# Convert the Ubuntu package to Arch package
echo "Converting Ubuntu package..."
debtap QNAPQsyncClientUbuntux64.deb

# Install the converted package
echo "Installing Qsync..."
sudo pacman -U qnapqsyncclient*.pkg.tar.zst --assume-installed android-emulator --assume-installed anaconda --assume-installed plex-media-server --assume-installed activitywatch-bin --assume-installed cura-bin --assume-installed clion --assume-installed fcitx-qt5

# Remove downloaded deb package (optional)
rm -f QNAPQsyncClientUbuntux64.deb

echo "QNAP Qsync installation complete."

