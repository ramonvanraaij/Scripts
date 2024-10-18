#!/bin/bash

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
# Replace the URL with the latest version from https://www.qnap.com/en/utilities/essentials#utliity_3
DOWNLOAD_URL="https://download.qnap.com/Storage/Utility/QNAPQsyncClientUbuntux64-LATEST.deb"
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

