#!/bin/bash
# sshjump.sh
# =================================================================
# SSH Jump Host Wrapper Script
# Copyright (c) 2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
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

# --- Configuration ---
# Your jump host details
JUMP_HOST_USERNAME="user" # Change this to your jump host username
JUMP_HOST_ADDRESS="your_jump_host_ip_or_hostname" # Change this to your jump host IP or hostname
JUMP_HOST_PORT="22" # Change this to your jump host's SSH port

# Construct the -J argument for SSH
JUMP_ARG="-J ${JUMP_HOST_USERNAME}@${JUMP_HOST_ADDRESS}:${JUMP_HOST_PORT}"
# --- End Configuration ---


# Check if any arguments were provided
if [ -z "$1" ]; then
  echo "Usage: $0 [user@]final_server_hostname_or_ip [-p final_server_port] [other_ssh_options]"
  echo "Example: $0 user@myfinalhost.com -p 2222"
  exit 1
fi

# Execute the SSH command
# We use 'eval' here because the JUMP_ARG contains a colon which might
# be misinterpreted without proper quoting when combined with other arguments,
# and passing it as a single string to ssh ensures it's treated as one argument.
# "$@" expands all arguments passed to the script, preserving spaces and quotes.
eval "ssh $JUMP_ARG \"$@\""
