#!/bin/bash
# sshjump.sh
# =================================================================
# SSH Jump Host Wrapper Script
# Copyright (c) 2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
# =================================================================
# This script simplifies connecting to a final SSH server via a
# predefined jump host.
#
# Usage:
# sshjump.sh [user@]final_server_hostname_or_ip [-p final_server_port] [other_ssh_options]
#
# Example:
# ./sshjump.sh user@myfinalhost.com -p 2222
#
# Make sure to set execute permissions: chmod +x sshjump.sh
# =================================================================

set -o errexit -o nounset -o pipefail

# --- Configuration ---
# Your jump host details. These values can be overridden by command-line flags.
JUMP_HOST="user@your_jump_host_ip_or_hostname" # Change this to your jump host IP or hostname
JUMP_PORT="22" # Change this to your jump host's SSH port
FINAL_USER=""
# --- End Configuration ---

# --- Functions ---
usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [user@]final_server_hostname_or_ip [-p final_server_port] [other_ssh_options]

This script simplifies connecting to a final SSH server via a predefined jump host.

Options:
  -s HOST      The address of the jump host (e.g., user@host).
               (Default: $JUMP_HOST)
  -P PORT      The port of the jump host.
               (Default: $JUMP_PORT)
  -p PORT      The port of the final destination.
  -u USER      The username for the final destination.
  -h           Show this help message and exit.

Example:
  $(basename "$0") -s user@jumphost -u finaluser myfinalhost.com -p 2222
EOF
  exit 0
}
# --- End Functions ---

# --- Argument Parsing ---
while getopts "s:P:u:h" opt; do
  case $opt in
    s) JUMP_HOST="$OPTARG" ;;
    P) JUMP_PORT="$OPTARG" ;;
    u) FINAL_USER="$OPTARG" ;;
    h) usage ;;
    \?) usage ;;
  esac
done
shift $((OPTIND-1))
# --- End Argument Parsing ---

# Check if a final destination was provided
if [ -z "${1-}" ]; then
  echo "Error: No final destination specified."
  usage
fi

# Construct the -J argument for SSH
JUMP_ARG="-J${JUMP_HOST}:${JUMP_PORT}"

# Construct the final destination string
FINAL_DESTINATION="$1"
if [ -n "$FINAL_USER" ]; then
  FINAL_DESTINATION="${FINAL_USER}@${FINAL_DESTINATION}"
fi

# Execute the SSH command
ssh_args=()
ssh_args+=("$JUMP_ARG")
ssh_args+=("$FINAL_DESTINATION")
shift
ssh_args+=("$@")

ssh "${ssh_args[@]}"
