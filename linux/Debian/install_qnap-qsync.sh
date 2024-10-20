#!/bin/bash

# Copyright (c) 2024 Rámon van Raaij

# License: MIT

# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu

# install_qnap-qsync.sh - This script installs QNAP Qsync on Ubuntu with optional KDE Plasma Wayland support. It updates package lists, installs dependencies, downloads the latest Qsync package, installs it using dpkg, fixes dependency issues, and optionally removes the downloaded file.

# Check if KDE Plasma Wayland is installed (optional)
if grep -q "KDE Plasma (Wayland)" /etc/xdg/desktop/kde-plasma.desktop; then
  echo "KDE Plasma Wayland detected."
else
  echo "KDE Plasma Wayland not detected."
fi

# Update package lists
echo "Updating package lists..."
sudo apt update

# Install required dependencies
echo "Installing dependencies..."
sudo apt install libasound2 libxtst6 libnss3 libusb-1.0-0 qtwayland5

# Download the latest Qsync package for Ubuntu (x64)
DOWNLOAD_URL=$(curl -sL https://update.qnap.com/SoftwareRelease.xml | xmllint --xpath '/docRoot/utility/application[applicationName="com.qnap.qsync"]/platform[platformName="Ubuntu"]/software/downloadURL' - | sed 's/<\/downloadURL>//; s/<downloadURL>//'| head -n 1)
DOWNLOAD_FILE="QNAPQsyncClientUbuntux64.deb"

wget -O "$DOWNLOAD_FILE" "$DOWNLOAD_URL"

# Install Qsync
echo "Installing Qsync..."
sudo dpkg -i "$DOWNLOAD_FILE"

# Fix potential dependency issues
echo "Fixing potential dependency issues..."
sudo apt --fix-broken install

# Optional: Remove downloaded deb package
# Uncomment the following line to remove the downloaded deb after installation
# rm -f "$DOWNLOAD_FILE"

echo "QNAP Qsync installation complete."

