#!/bin/bash

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
# Replace LATEST with the actual version number from https://www.qnap.com/en/utilities/essentials#utliity_3
DOWNLOAD_URL="https://download.qnap.com/Storage/Utility/QNAPQsyncClientUbuntux64-LATEST.deb"
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

