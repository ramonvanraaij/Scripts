#!/bin/bash

# Copyright (c) 2024 Rámon van Raaij

# License: MIT

# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu

# install_homebrew.sh - This script first asks for your permission to install Homebrew package manager for Linux. If you agree, it downloads and executes the official installation script. Finally, it configures your shell profile to recognize Homebrew commands and recommends opening a new terminal window for the changes to work.

echo "This script will install Homebrew package manager for Linux."

read -p "Do you want to proceed? (y/N) " -n 1 -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Exiting..."
  exit 0
fi

if curl -fsSL https://raw.githubusercontent.com/Linuxbrew/install/master/install.sh | sh -s ; then
  echo "Homebrew installation successful!"

  shell_profile=~/.bash_profile

  case "$SHELL" in
    "/bin/bash")  ;;
    "/bin/zsh")  shell_profile=~/.zshrc ;;
    "/bin/fish")  shell_profile=~/.config/fish/config.fish ;;
    *) echo "Unsupported shell. Configuration not added." ;;
  esac

  # Add configuration to the appropriate shell profile
  echo '# Homebrew' >> "$shell_profile"
  echo '[ -d /home/linuxbrew/.linuxbrew ] && eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)' >> "$shell_profile"
  echo 'export XDG_DATA_DIRS="/home/linuxbrew/.linuxbrew/share:$XDG_DATA_DIRS"' >> "$shell_profile"

  # Make it working right away
  [ -d /home/linuxbrew/.linuxbrew ] && eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)
  export XDG_DATA_DIRS="/home/linuxbrew/.linuxbrew/share:$XDG_DATA_DIRS"

  echo "Please open a new terminal window for the changes to take effect."
  echo "Run 'brew doctor' to verify your Homebrew installation."
else
  echo "Error installing Homebrew. Please check the logs for details."
  exit 1
fi

