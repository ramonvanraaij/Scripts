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

    # Make sure temporary directory exists (optional)
    mkdir -p /tmp

    # Clone yay from AUR, build, and install (with confirmation)
    cd /tmp && git clone https://aur.archlinux.org/yay.git
    cd yay && makepkg -si

    # Clean up temporary directory
    cd /tmp && rm -rf yay
  fi
  echo "yay installation complete."
fi

# Install snapd and apparmor
yay -S snapd apparmor squashfs-tools

# Enable and start snapd systemd unit
sudo systemctl enable --now snapd.socket
sleep 5
# Enable and start apparmor systemd unit
sudo systemctl enable --now snapd.apparmor.service

# Enable classic snap support
sudo ln -s /var/lib/snapd/snap /snap
sleep 5
# Install Snap Store
sudo snap install snap-store
