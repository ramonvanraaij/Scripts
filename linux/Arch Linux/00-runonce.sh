#!/bin/sh

# Copyright (c) 2024 Rámon van Raaij

# License: MIT

# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu

# 00-runonce.sh
# This script is an interactive system setup tool for Arch Linux users.
# It guides the user through various configuration options with informative
# questions and validation checks. Here's a breakdown:

# 1. Security Checks:
#    - Ensures the script is not run with sudo or root privileges (prevents accidental system damage).

# 2. System Updates:
#    - Asks the user if they want to fully update the system using `pacman`.

# 3. OpenSSH Server:
#    - Asks if the user wants to install the OpenSSH server.
#    - Offers options to start and enable the server at boot time.

# 4. Firewall:
#    - Asks if the user wants to install the `ufw` firewall.
#    - Guides the user through allowing SSH traffic and enabling the firewall.

# 5. Bluetooth:
#    - Asks if the user wants to install Bluetooth support.
#    - Offers options to start and enable Bluetooth at boot time.

# 6. Fish Shell:
#    - Asks if the user wants to install and use the `fish` shell.
#    - Modifies the user's `.bashrc` file to set `fish` as the default shell.

# 7. Flatpak with Flathub:
#    - Sets up the Flathub store for installing flatpak applications.

# 8. Yay AUR Helper:
#    - Asks if the user wants to install the `yay` AUR helper for accessing the Arch User Repository.
#    - Provides instructions for installation.

# 9. Chaotic-AUR Repository:
#    - Asks if the user wants to add the Chaotic-AUR repository for additional packages.
#    - Guides the user through adding the repository key and configuration.

# 10. Reflector Package Manager Mirror Selection:
#    - Asks if the user wants to install `reflector` to improve pacman mirror selection.
#    - Offers options to prioritize specific countries and enable the reflector service for automatic updates.

# 11. Homebrew Installation:
#    - Asks if the user wants to install Homebrew for package management on Linux.
#    - Configures Homebrew for the user's shell and prompts the user to run `brew doctor` for verification.

# 12. KDE Plasma Desktop Environment (Optional):
#    - Asks if the user wants to install the KDE Plasma desktop environment.
#    - Offers options to install additional KDE applications and set it as the default desktop at boot time.

# 13. SSH Key Generation (Optional):
#    - Guides the user through creating an SSH key for GitHub authentication.
#    - Provides instructions for adding the key to the user's GitHub account.

# 14. Chezmoi Configuration Management (Optional):
#    - Asks if the user wants to install Chezmoi for managing dotfiles.
#    - Guides the user through initialization with their GitHub username and applying the configuration.

# This script offers a comprehensive and user-friendly way to customize a new Arch Linux installation.
# It prioritizes security checks, provides clear options, and offers helpful instructions for each step.

# Check if script is run with sudo or root
if [[ $EUID -eq 0 ]]; then
  echo "Error: This script should not be run with sudo or as root."
  exit 1
fi

# Function to ask a yes/no question and validate input
ask_yes_no() {
  local question="$1"

  while true; do
    read -p "$question :" answer
    case "$answer" in
      [yY])
        return 0
        ;;
      [nN])
        return 1
        ;;
      *)
        echo "Invalid input. Please enter 'y' or 'n'."
        ;;
    esac
  done
}

# Function to validate email address
validate_email() {
  local email="$1"
  email_regex='^[^@]+@[^@]+\.[^@]+$'
  if [[ ! $email =~ $email_regex ]]; then
    echo "Invalid email address. Please enter a valid email address."
    return 1
  fi
  return 0
}

# Function to validate GitHub username
validate_username() {
  local username="$1"
  username_regex='^[a-zA-Z0-9-]+$'
  if [[ ! $username =~ $username_regex ]]; then
    echo "Invalid username. Usernames can only contain alphanumeric characters and dashes (-)."
    return 1
  fi
  return 0
}

# Ask if the user wants to fully update the system
if ask_yes_no "Do you want to fully update the system? (y/n)"; then
  # Update the system
  sudo pacman -Syu --noconfirm
fi

# Ask if the user wants to install the OpenSSH server
if ask_yes_no "Do you want to install the OpenSSH server? (y/n)"; then
  # Install OpenSSH server
  sudo pacman -Sy --needed openssh --noconfirm

  # Ask if the user wants to start the OpenSSH server
  if ask_yes_no "Do you want to start the OpenSSH server now? (y/n)"; then
    sudo systemctl start sshd
  fi

  # Ask if the user wants to enable the OpenSSH server at boot time
  if ask_yes_no "Do you want to enable the OpenSSH server at boot time? (y/n)"; then
    sudo systemctl enable sshd
  fi
fi

# Ask if the user wants to install a firewall
if ask_yes_no "Do you want to install a firewall (ufw)? (y/n)"; then
  # Install firewall
  sudo pacman -S ufw --noconfirm

  # Ask if the user wants to allow SSH traffic
  if ask_yes_no "Do you want to allow SSH traffic (port 22)? (y/n)"; then
    sudo ufw allow ssh
  else
    echo "Warning: If you do not allow SSH traffic, you will not be able to access this system remotely using SSH."
    if ! ask_yes_no "Are you sure you want to continue without allowing SSH traffic? (y/n)"; then
      sudo ufw allow ssh
    fi
  fi

  # Ask if the user wants to enable the firewall at boot time
  if ask_yes_no "Do you want to enable the firewall at boot time? (y/n)"; then
    sudo ufw enable
  fi
fi

# Ask if the user wants to install Bluetooth support
if ask_yes_no "Do you want to install Bluetooth support? (y/n)"; then
  # Install Bluetooth packages
  sudo pacman -Sy --needed bluez bluez-utils bluez-deprecated-tools --noconfirm
  
  # Ask if the user wants to start and enable Bluetooth
  if ask_yes_no "Do you want to start Bluetooth and enable it at boot time? (y/n)"; then
    sudo systemctl enable --now bluetooth
  fi
fi

# Ask if the user wants to install fish and use it as the current user
if ask_yes_no "Do you want to install the friendly interactive shell (fish) and use it as the current user? (y/n)"; then
  # Install fish
  sudo pacman -Sy --needed fish --noconfirm

  # Add fish to ~/.bashrc
  echo "# fish: friendly interactive shell" >> ~/.bashrc
  echo "exec fish" >> ~/.bashrc
  echo "# Add nothing else here as fish is the shell in use" >> ~/.bashrc
  echo "# Open a new fish shell" >> ~/.bashrc
  echo "exec fish" >> ~/.bashrc
fi

# Ask if the user wants to use flatpak with Flathub store
if ask_yes_no "Do you want to use flatpak with the Flathub store? (y/n)"; then
  # Remove system-wide Flathub remote (if exists)
  sudo pacman -Sy --needed flatpak --noconfirm
  sudo flatpak remote-delete flathub

  # Add Flathub remote for the current user
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo --user
fi

# Ask if the user wants to install yay AUR helper
if ask_yes_no "Do you want to install the yay AUR helper? (y/n)"; then
  # Install required packages
  sudo pacman -S --needed git base-devel --noconfirm
  # Install Yay
  cd ~
  git clone https://aur.archlinux.org/yay.git
  cd yay
  makepkg -si
  cd ~
  rm -rf yay
fi

# Ask if the user wants to add the Chaotic-AUR repository
if ask_yes_no "Do you want to add the Chaotic-AUR repository? (y/n)"; then
  # Add Chaotic-AUR repository
  sudo pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
  sudo pacman-key --lsign-key 3056513887B78AEB
  sudo pacman -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
  sudo pacman -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
  sudo sh -c "cat >>/etc/pacman.conf" <<-EOF
[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
EOF
  sudo pacman -Sy
fi

# Ask if the user wants to install reflector
if ask_yes_no "Do you want to install reflector to improve pacman mirror selection? (y/n)"; then
  # Install reflector package
  sudo pacman -S reflector --noconfirm --needed

  # Ask for countries (optional)
  read -p "Enter comma-separated list of countries to prioritize (e.g., France,Germany) [leave blank for default]: " countries

  # Update reflector configuration with countries (if provided)
  if [[ -n "$countries" ]]; then
    sudo sed -i "s/# --country France,Germany/--country $countries/g" /etc/xdg/reflector/reflector.conf
  fi

  # Change sorting method to rate
  sudo sed -i 's#--sort age#--sort rate#g' /etc/xdg/reflector/reflector.conf

  # Ask if the user wants to enable the reflector service
  if ask_yes_no "Do you want to enable the reflector service to automatically update mirrors? (y/n)"; then
    sudo systemctl enable reflector
    sudo systemctl start reflector
  fi

  echo "Reflector installed and configured (if countries provided)."
fi

# Ask if the user wants to install Homebrew
if ask_yes_no "Do you want to install Homebrew? (y/n)"; then
  # Install Homebrew
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"
  # Add Homebrew configuration
  echo '# Homebrew' >> ~/.bash_profile
  echo '[ -d /home/linuxbrew/.linuxbrew ] && eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)' >> ~/.bash_profile
  echo 'export XDG_DATA_DIRS="/home/linuxbrew/.linuxbrew/share:$XDG_DATA_DIRS"' >> ~/.bash_profile

  # Check if fish is installed
  if command -v fish >/dev/null 2>&1; then
    echo '# Homebrew (fish)' >> ~/.config/fish/config.fish
    echo '[ -d /home/linuxbrew/.linuxbrew ] && eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)' >> ~/.config/fish/config.fish
    echo 'export XDG_DATA_DIRS="/home/linuxbrew/.linuxbrew/share:$XDG_DATA_DIRS"' >> ~/.config/fish/config.fish
  fi

  # Make it working right away
  [ -d /home/linuxbrew/.linuxbrew ] && eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)
  export XDG_DATA_DIRS="/home/linuxbrew/.linuxbrew/share:$XDG_DATA_DIRS"

  # Check if Homebrew is working
  brew doctor
fi

# Ask if the user wants to install the KDE Plasma Desktop Environment
if ask_yes_no "Do you want to install the KDE Plasma Desktop Environment? (y/n)"; then
  # Install KDE Plasma Desktop Environment
  sudo pacman -Sy --needed plasma sddm sddm-kcm qt5-declarative qt6-declarative --noconfirm

  # Enable NetworkManager to start on boot
  sudo systemctl enable NetworkManager

  # Ask if the user wants to install all KDE Applications
  if ask_yes_no "Do you want to install all KDE Applications? (y/n)"; then
    sudo pacman -Sy --needed kde-applications --noconfirm
  fi

  # Ask if the user wants to enter the Desktop environment at boot time
  if ask_yes_no "Do you want to enter the Desktop environment at boot time? (y/n)"; then
    sudo systemctl enable sddm.service
  fi
fi

# Ask if the user wants to create an SSH key
if ask_yes_no "Do you want to create an SSH key to be used for GitHub authentication? (y/n)"; then
  # Get user email address
  while true; do
    read -p "Enter your email address for the SSH key: " email
    if validate_email "$email"; then
      break
    fi
  done

  # Generate SSH key
  ssh-keygen -t ed25519 -C "$email"

  # Display public key
  echo "Generated Public key:"
  cat ~/.ssh/id_ed25519.pub

  echo "**Instructions:**"
  echo "1. Copy the displayed public key."
  echo "2. Go to your GitHub account settings (https://github.com/settings/keys)."
  echo "3. Click on 'New SSH key' and paste the copied key into the 'Key' field."
  echo "4. Give your key a descriptive title (e.g., 'Your Computer Name')."
  echo "5. Click 'Add SSH key'."

  # Pause script and wait for user confirmation
  read -p "Press any key to continue after adding the SSH key to your GitHub account..."

fi

# Ask if the user wants to install Chezmoi
if ask_yes_no "Do you want to install Chezmoi? (y/n)"; then
  # Install Chezmoi dependencies and Chezmoi itself only if user confirms
  sudo pacman -Sy --needed base-devel git gcc chezmoi gvim vi go nano

  # If Chezmoi installation was confirmed, continue with configuration
  if [[ $? -eq 0 ]]; then
    # Ask if the user wants to initialize Chezmoi
    if ask_yes_no "Do you want to initialize Chezmoi? (y/n)"; then
      # Get GitHub username only if initialization is confirmed
      while true; do
        read -p "Enter your GitHub username: " username
        if validate_username "$username"; then
          break
        fi
      done

      # Initialize Chezmoi
      chezmoi init "git@github.com:$username/dotfiles.git"

      # Ask if the user wants to apply Chezmoi only if initialization is successful
      if [[ $? -eq 0 ]]; then
        if ask_yes_no "Do you want to apply Chezmoi? (y/n)"; then
          # Apply Chezmoi configuration
          chezmoi apply
        fi
      fi
    fi
  fi
fi
