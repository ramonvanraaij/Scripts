#!/bin/sh

# Copyright (c) 2025 Rámon van Raaij

# License: MIT

# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu

# system-update.sh - This script prompts once a day to update Arch Linux

red=$(tput setaf 1)
normal=$(tput sgr0)

if [ ! -f ~/.update/$(date +%F) ]; then
  mkdir -p ~/.update
  rm -f ~/.update/*
  touch ~/.update/$(date +%F)
  echo "Performing daily system update"
  sudo pacman -Syuq

  if command -v yay &> /dev/null; then # Check if yay exists
    yay -Syuq \
      --aur \
      --needed \
      --noconfirm \
      --norebuild \
      --noredownload
  else
    echo "yay not found, skipping AUR updates."
  fi

  printf "\n\n%40s\n\n" "${red}You should reboot the system${normal}"
fi
