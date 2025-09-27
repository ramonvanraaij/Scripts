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

# --- Git Repository Updates ---
# Set to "true" to enable automatic `git pull` for the repos listed below.
readonly GIT_UPDATE_ENABLED="false"

# A list of absolute paths to the local git repositories to update.
# Add your own repositories here.
readonly REPOS_TO_UPDATE=(
    "$HOME/Scripts"
    "$HOME/.local/share/chezmoi"
)


# --- Define color variables for styled terminal output ---
# RED is used for the final reboot message to make it stand out.
# NORMAL resets the text formatting to the terminal's default.
RED=$(tput setaf 1)
NORMAL=$(tput sgr0)

# --- Define the path for the daily update marker file ---
# The script creates a file with the current date (YYYY-MM-DD) as its name.
# This file is used to check if the update has already been run today.
UPDATE_MARKER="$HOME/.cache/system-update/$(date +%F)"

# --- Check if the daily update has already been performed ---
# If a marker file with today's date exists, the script will exit.
if [ -f "$UPDATE_MARKER" ]; then
    printf "Daily system update already performed today. Exiting.\n"
    exit 0
fi

# --- Create the marker directory and file ---
# This ensures that subsequent runs of the script on the same day will exit early.
mkdir -p "$HOME/.cache/system-update"
touch "$UPDATE_MARKER"

printf "Performing daily system update...\n"

# A function to navigate into a git repository, pull the latest
# changes, and report its status.
#
# $1: The absolute path to the local git repository.
pull_repo() {
    REPO_PATH="$1"
    REPO_NAME=$(basename "$REPO_PATH")

    printf "\nChecking %s repo...\n" "$REPO_NAME"
    if [ -d "$REPO_PATH" ]; then
        # Use a subshell `()` to change directory, so we don't have to `cd` back.
        # `git pull --ff-only` ensures the pull only proceeds if it's a fast-forward,
        # preventing merges that would require manual intervention.
        (cd "$REPO_PATH" && git pull --ff-only)
    else
        printf "Warning: %s not found at %s, skipping.\n" "$REPO_NAME" "$REPO_PATH"
    fi
}

# --- Pulling from various Git repositories ---
if [ "${GIT_UPDATE_ENABLED}" = "true" ]; then
    # Loop through the array and call the pull_repo function for each path.
    for repo in "${REPOS_TO_UPDATE[@]}"; do
        pull_repo "$repo"
    done
else
    printf "\nGit repository updates are disabled. Skipping.\n"
fi

# --- Update system packages with pacman ---
# -Syu: Syncs repositories and upgrades all out-of-date packages.
# --noconfirm: Skips all "Are you sure?" confirmation prompts.
# --needed: Prevents re-installing packages that are already up to date.
# --quiet: Reduces the amount of output.
printf "\nChecking for pacman updates...\n"
sudo pacman -Syu --noconfirm --needed --quiet

# --- Check for and update AUR packages with yay ---
# First, check if the `yay` command is installed and available.
if command -v yay >/dev/null; then
    printf "\nChecking for yay updates...\n"
    # The `-Syu` command for yay works similarly to pacman but also
    # includes packages from the AUR.
    yay -Syu --noconfirm --quiet
else
    printf "\nyay not found, skipping AUR updates.\n"
fi

# --- Inform the user about a necessary reboot ---
# A reboot is recommended after a system update, especially if the
# kernel or other core system components were updated.
printf "\n\n%40s\n\n" "${RED}System update complete. You should reboot the system.${NORMAL}"
