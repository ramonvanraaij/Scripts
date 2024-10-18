#!/bin/sh

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

