# Copyright (c) 2024 Rámon van Raaij

# License: MIT

# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu

# Script to create and update an AlmaLinux OS, Arch Linux, Debian, or Ubuntu pod with usefull packages installed, using distrobox

# Dependencies: distrobox, wget, jq

# Function to create the pod
create_pod() {
  # Ask user for OS choice
  while true; do
    echo "1: AlmaLinux OS"
    echo "2: Arch Linux"
    echo "3: Debian"
    echo "4: Kali Linux"
    echo "5: Ubuntu"
    read -p "Choose OS (1, 2, 3, 4, 5): " choice

    # Validate user input
    if [[ "$choice" =~ ^(1|2|3|4|5|6)$ ]]; then
      break
    else
      echo "Invalid choice. Please enter '1', '2', '3', '4', or '5'."
    fi
  done

  # Set pod name and OS based on chosen number
  case "$choice" in
  1)
    #pod_name="almalinux"
    os="almalinux"
    package_manager="dnf"
    package_list="bat fish ugrep eza htop wget"
    fastfetch_install="rpm"
    ;;
  2)
    #pod_name="archlinux"
    os="archlinux"
    package_manager="pacman"
    package_list="bat fish ugrep eza htop wget ttf-hack-nerd fastfetch"
    ;;
  3)
    #pod_name="debian"
    os="debian"
    package_manager="apt"
    package_list="bat fish ugrep exa htop wget fonts-hack-ttf"
    fastfetch_install="deb"
    ;;
  4)
    pod_name="kali-linux"
    os="kali-rolling"
    package_manager="apt"
    package_list="bat fish ugrep eza htop wget fonts-hack-ttf kali-linux-headless kali-linux-large"
    fastfetch_install="deb"
    ;;

  5)
    #pod_name="ubuntu"
    os="ubuntu"
    package_manager="apt"
    package_list="bat fish ugrep eza htop wget fonts-hack-ttf"
    fastfetch_install="deb"
    ;;
  esac

  # Ask for a pod name (optional)
  while true; do
    read -p "Enter the name of this pod (leave blank for default): " pod_name

    # Validate pod name format (allow letters, numbers, hyphens, underscores, spaces, and periods)
    if [[ -n "$pod_name" && ! "$pod_name" =~ ^[[:alnum:].\_\-]+$ ]]; then
      echo "Invalid pod name. Please use only letters, numbers, hyphens, underscores, and periods."
    else
      echo "Entered pod name: $pod_name" # Added to see captured input
      # If pod name is empty, set it to the OS name
      if [[ -z "$pod_name" ]]; then
        pod_name="$os"
        echo "Pod name is empty, set to OS name: $pod_name" # Added to see empty check
      fi
      break
    fi
  done

  # Create the pod with the chosen OS image
  distrobox create -i "${os}:latest" -n "${pod_name}"

  # Update and enter the pod
  distrobox upgrade "${pod_name}"

  # Install default packages based on chosen OS
  if [[ "$package_manager" == "pacman" ]]; then
    distrobox enter "${pod_name}" -- sudo "$package_manager" --noconfirm --needed -Syu $package_list
    distrobox enter "${pod_name}" -- sudo ln -s /usr/bin/bat /usr/bin/batcat
  elif [[ "$package_manager" == "apt" ]]; then
    distrobox enter "${pod_name}" -- sudo "$package_manager" -y install $package_list
  elif [[ "$package_manager" == "dnf" ]]; then
    distrobox enter "${pod_name}" -- sudo "$package_manager" -y install epel-release
    distrobox enter "${pod_name}" -- sudo "$package_manager" -y install $package_list
    distrobox enter "${pod_name}" -- sudo ln -s /usr/bin/bat /usr/bin/batcat
  fi

  # Install fastfetch for Debian/Ubuntu
  if [[ "$fastfetch_install" == "deb" ]]; then
    # Download and install the latest fastfetch release
    FASTFETCH_VERSION=$(curl -s https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest | jq -r '.tag_name')
    distrobox enter "${pod_name}" -- wget -O fastfetch.deb https://github.com/fastfetch-cli/fastfetch/releases/download/$FASTFETCH_VERSION/fastfetch-linux-amd64.deb
    distrobox enter "${pod_name}" -- sudo dpkg -i fastfetch.deb

    # Clean up downloaded file (optional)
    distrobox enter "${pod_name}" -- rm fastfetch.deb
  fi

  # Install fastfetch for AlmaLinux OS
  if [[ "$fastfetch_install" == "rpm" ]]; then
    # Download and install the latest fastfetch release
    FASTFETCH_VERSION=$(curl -s https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest | jq -r '.tag_name')
    distrobox enter "${pod_name}" -- wget -O fastfetch.rpm https://github.com/fastfetch-cli/fastfetch/releases/download/$FASTFETCH_VERSION/fastfetch-linux-amd64.rpm
    distrobox enter "${pod_name}" -- sudo rpm -i fastfetch.rpm

    # Clean up downloaded file (optional)
    distrobox enter "${pod_name}" -- rm fastfetch.rpm
  fi

  echo "${os^} pod '${pod_name}' set up with default tools and fastfetch."
}

# Call the create_pod function
create_pod
