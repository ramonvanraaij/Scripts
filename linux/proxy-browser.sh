#!/bin/bash
# proxy-browser.sh
# =================================================================
# SSH SOCKS Proxy Browser Launcher
# Copyright (c) 2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
# =================================================================
# This script performs the following actions:
# 1. Establishes an SSH SOCKS proxy connection in the background.
# 2. Launches a web browser configured to use that proxy.
# 3. Automatically terminates the SSH connection when the browser is closed.
#
# Usage:
# 1. Customize the variables in the "Configuration" section below.
# 2. Make the script executable: chmod +x proxy-browser.sh
# 3. Run the script from your terminal: ./proxy-browser.sh
# =================================================================

# --- Configuration ---
SSH_HOST="192.168.0.123"
PROXY_PORT="1080"

# Set the command for the browser you want to use.
# Examples:
#   google-chrome-stable
#   chromium
#   brave
#   microsoft-edge-stable
BROWSER_COMMAND="brave"
# --- End Configuration ---


# This function will be called when the script exits for any reason.
cleanup() {
  # Check if the SSH_PID variable is set
  if [ -n "$SSH_PID" ]; then
    echo "Browser closed. Terminating SSH connection (PID: $SSH_PID)..."
    # Kill the background SSH process
    kill "$SSH_PID"
    echo "Connection closed."
  fi
}

# 'trap' ensures that the cleanup function is called when the script exits.
trap cleanup EXIT

echo "Starting SSH SOCKS proxy to $SSH_HOST on port $PROXY_PORT..."

# Start the SSH connection in the background.
# -N: Do not execute a remote command. This is useful for just forwarding ports.
# -q: Quiet mode.
ssh -N -q -D "$PROXY_PORT" "$SSH_HOST" &

# Get the Process ID (PID) of the background SSH process we just started.
SSH_PID=$!

# Give the proxy a moment to establish itself before launching the browser.
sleep 2

echo "Launching $BROWSER_COMMAND through the proxy (SSH PID: $SSH_PID)..."
echo "Close the browser window to terminate the SSH connection."

# Launch the specified browser using the proxy. The script will wait on this line
# until you close the browser.
"$BROWSER_COMMAND" --proxy-server="socks5://localhost:$PROXY_PORT" --new-window
