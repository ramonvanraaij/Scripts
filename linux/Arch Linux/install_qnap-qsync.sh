#!/bin/bash

# Copyright (c) 2024 Rámon van Raaij

# License: MIT

# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu

# install_qnap-qsync.sh - This script installs QNAP Qsync on Arch Linux. It checks for KDE Plasma, installs debtap if needed, updates package lists, downloads the Qsync package, converts it to Arch format, installs it, cleans up, and provides confirmation.

# **Note:**
# This script relies on `debtap` for conversion, which might not guarantee perfect compatibility.

# Check for KDE Plasma (optional)
# if [[ $(wmctrl -m | grep name | grep -i "KDE Plasma") ]]; then
#   echo "KDE Plasma detected."
# fi

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
wget -O QNAPQsyncClientUbuntux64.deb "$DOWNLOAD_URL"

# Convert the Ubuntu package to Arch package
echo "Converting Ubuntu package..."
debtap QNAPQsyncClientUbuntux64.deb

# Install the converted package
echo "Installing Qsync..."
sudo pacman -U qnapqsyncclient*.pkg.tar.zst

# Remove downloaded deb package (optional)
rm -f QNAPQsyncClientUbuntux64.deb

echo "QNAP Qsync installation complete."

