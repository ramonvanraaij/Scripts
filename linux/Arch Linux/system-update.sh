#!/usr/bin/env bash

# =================================================================
# Arch Linux System Update Script
#
# Copyright (c) 2024-2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script automates the daily update process for an Arch Linux
# system. It updates system packages from official repositories
# (pacman) and the Arch User Repository (yay), and also pulls
# updates for specified local git repositories.
#
# It is designed to be run once per day, using a marker file to
# prevent multiple runs on the same day.
#
# --- Usage & Automation ---
# 1. Make the script executable:
#    chmod +x /path/to/your/script/system-update.sh
#
# 2. To run this script automatically every time you open a terminal,
#    add the following line to the end of your shell's startup file:
#
#    For bash users, add to ~/.bashrc:
#    /path/to/your/script/system-update.sh
#
#    For fish users, add to ~/.config/fish/config.fish:
#    /path/to/your/script/system-update.sh
# =================================================================

# --- Script Configuration ---
# Set to "true" to enable automatic `git pull` for the repos listed below.
readonly GIT_UPDATE_ENABLED="true"

# Log file for recording update history.
readonly LOG_FILE="$HOME/.cache/system-update/system-update.log"

# A list of absolute paths to the local git repositories to update.
# Add your own repositories here.
# A list of absolute paths to the local git repositories to update.
# Add your own repositories here.
# For other users, these paths might not exist. Uncomment and configure as needed.
# readonly REPOS_TO_UPDATE=(
#     "$HOME/Projects/Scripts"
#     "$HOME/.local/share/chezmoi"
# )

# Color codes for echo
BLUE="\e[34m"
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

# Function to print a colored message
print_message() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${RESET}"
}

# Stop script on errors
set -e

# --- Daily Update Check ---
# The script checks if an update has already been performed today.
# To bypass this check, run the script with the --force flag.
UPDATE_MARKER="$HOME/.cache/system-update/$(date +%F)"

if [ -f "$UPDATE_MARKER" ] && [ "$1" != "--force" ]; then
    print_message "$GREEN" "Daily system update already performed today. Exiting.\n"
    exit 0
fi

# --- Sudo Privilege Check ---
# The script requires sudo privileges to run system updates.
# This check ensures that the script has the necessary permissions before proceeding.
print_message "$BLUE" "Sudo privileges are required for the daily system update."
if ! sudo -v; then
    print_message "$RED" "Failed to obtain sudo privileges. Exiting."
    exit 1
fi

# --- Create the marker directory and file ---
# This ensures that subsequent runs of the script on the same day will exit early.
mkdir -p "$HOME/.cache/system-update"
touch "$UPDATE_MARKER"

printf "Performing daily system update...\n" | tee -a "$LOG_FILE"

# A function to navigate into a git repository, pull the latest
# changes, and report its status.
#
# $1: The absolute path to the local git repository.
pull_repo() {
    REPO_PATH="$1"
    REPO_NAME=$(basename "$REPO_PATH")

    printf "\nChecking %s repo...\n" "$REPO_NAME" | tee -a "$LOG_FILE"
    if [ -d "$REPO_PATH" ]; then
        # Use a subshell `()` to change directory, so we don't have to `cd` back.
        # `git pull --ff-only` ensures the pull only proceeds if it's a fast-forward,
        # preventing merges that would require manual intervention.
        (cd "$REPO_PATH" && git pull --ff-only) | tee -a "$LOG_FILE"
    else
        printf "Warning: %s not found at %s, skipping.\n" "$REPO_NAME" "$REPO_PATH" | tee -a "$LOG_FILE"
    fi
}

# --- Pulling from various Git repositories ---
if [ "${GIT_UPDATE_ENABLED}" = "true" ]; then
    # Loop through the array and call the pull_repo function for each path.
    for repo in "${REPOS_TO_UPDATE[@]}"; do
        pull_repo "$repo"
    done
else
    printf "\n\nGit repository updates are disabled. Skipping.\n" | tee -a "$LOG_FILE"
fi

# --- Update system packages with pacman ---
printf "\nChecking for pacman updates...\n" | tee -a "$LOG_FILE"
sudo pacman -Syu --noconfirm --needed --quiet | tee -a "$LOG_FILE"

# --- Check for and update AUR packages with yay ---
if command -v yay >/dev/null; then
    printf "\nChecking for yay updates...\n" | tee -a "$LOG_FILE"
    yay -Syu --noconfirm --quiet | tee -a "$LOG_FILE"
else
    printf "\n\nyay not found, skipping AUR updates.\n" | tee -a "$LOG_FILE"
fi

# --- Check for and update Flatpak packages ---
if command -v flatpak >/dev/null; then
    printf "\nChecking for Flatpak updates...\n" | tee -a "$LOG_FILE"
    flatpak update --assumeyes | tee -a "$LOG_FILE"
else
    printf "\n\nFlatpak not found, skipping updates.\n" | tee -a "$LOG_FILE"
fi

# --- Check for and update Snap packages ---
if command -v snap >/dev/null; then
    printf "\nChecking for Snap updates...\n" | tee -a "$LOG_FILE"
    sudo snap refresh | tee -a "$LOG_FILE"
else
    printf "\n\nSnap not found, skipping updates.\n" | tee -a "$LOG_FILE"
fi

# --- Check for and update Homebrew packages ---
if command -v brew >/dev/null; then
    printf "\nChecking for Homebrew updates...\n" | tee -a "$LOG_FILE"
    brew update | tee -a "$LOG_FILE"
    brew upgrade | tee -a "$LOG_FILE"
else
    printf "\n\nHomebrew not found, skipping updates.\n" | tee -a "$LOG_FILE"
fi

# --- Check for and update npm packages ---
if command -v npm >/dev/null; then
    printf "\nChecking for npm updates...\n" | tee -a "$LOG_FILE"
    npm update -g | tee -a "$LOG_FILE"
else
    printf "\n\nnpm not found, skipping updates.\n" | tee -a "$LOG_FILE"
fi

# --- Inform the user about a necessary reboot ---
printf "\n"
print_message "$RED" "System update complete. You should reboot the system.\n"