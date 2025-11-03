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
# 1. Optionally, customize the default values in the "Configuration" section.
# 2. Make the script executable: chmod +x proxy-browser.sh
# 3. Run the script from your terminal: ./proxy-browser.sh
#    For more options, run with -h: ./proxy-browser.sh -h
# =================================================================

set -o errexit -o nounset -o pipefail

# --- Configuration ---
# Default values can be overridden by environment variables or command-line arguments.
: "${SSH_HOST:="192.168.0.123"}"
: "${SSH_PORT_CONNECT:="22"}"
: "${PROXY_PORT:="1080"}"
: "${BROWSER_COMMAND:="brave"}"
# --- End Configuration ---

# --- Functions ---
usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [--] [browser_arguments...]

This script establishes an SSH SOCKS proxy and launches a web browser configured to use it.

Options:
  -s HOST      The SSH host to connect to.
               (Default: $SSH_HOST)
  -P PORT      The SSH connection port.
               (Default: $SSH_PORT_CONNECT)
  -p PORT      The local port to use for the SOCKS proxy.
               (Default: $PROXY_PORT)
  -b CMD       The browser command to execute.
               (Default: $BROWSER_COMMAND)
  -h           Show this help message and exit.

Examples:
  # Launch Brave browser through the default SSH host
  $(basename "$0")

  # Launch Brave through a specific SSH host and port
  $(basename "$0") -s user@example.com -P 2222 -p 9090 -b brave

  # Pass additional arguments to the browser (e.g., open a specific URL)
  $(basename "$0") -- --incognito https://www.duckduckgo.com
EOF
  exit 0
}
# --- End Functions ---

# --- Argument Parsing ---
while getopts "s:P:p:b:h" opt; do
  case $opt in
    s) SSH_HOST="$OPTARG" ;;
    P) SSH_PORT_CONNECT="$OPTARG" ;;
    p) PROXY_PORT="$OPTARG" ;;
    b) BROWSER_COMMAND="$OPTARG" ;;
    h) usage ;;
    \?) usage ;;
  esac
done
shift $((OPTIND-1))
# --- End Argument Parsing ---

# This function will be called when the script exits for any reason.
cleanup() {
  # Check if the SSH_PID variable is set and not empty
  if [ -n "${SSH_PID-}" ]; then
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
ssh -o BatchMode=yes -N -q -D "$PROXY_PORT" -p "$SSH_PORT_CONNECT" "$SSH_HOST" &

# Get the Process ID (PID) of the background SSH process we just started.
SSH_PID=$!

# Add a check to see if the SSH process started successfully
if ! kill -0 "$SSH_PID" > /dev/null 2>&1; then
  echo "Error: SSH proxy failed to start. Please check your SSH configuration and credentials."
  exit 1
fi

# Give the proxy a moment to establish itself before launching the browser.
sleep 1

echo "Launching $BROWSER_COMMAND through the proxy (SSH PID: $SSH_PID)..."
echo "Close the browser window to terminate the SSH connection."

# Launch the specified browser using the proxy. The script will wait on this line
# until you close the browser.
if [ $# -eq 0 ]; then
    "$BROWSER_COMMAND" --proxy-server="socks5://localhost:$PROXY_PORT" --new-window > /dev/null 2>&1
else
    "$BROWSER_COMMAND" --proxy-server="socks5://localhost:$PROXY_PORT" "$@" > /dev/null 2>&1
fi
