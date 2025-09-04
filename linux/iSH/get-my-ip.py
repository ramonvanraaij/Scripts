#!/usr/bin/env python3
# get-my-ip.py
# =================================================================
# IP Address Retrieval Tool
# Copyright (c) 2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
# =================================================================
# This script is specifically designed as a workaround for the iSH app on iOS,
# where standard Linux networking commands like "ip a" or "ifconfig" are not
# available.
#
# It performs the following actions:
# 1. Determines the local/LAN IP address by creating a temporary
#    connection to a public DNS server.
# 2. Discovers the public/WAN IP address by querying an external API.
# 3. Prints both IP addresses to the terminal.
#
# Usage:
# Run the script from your terminal: python3 get-my-ip.py
# =================================================================

import socket
import urllib.request

# --- Get Local/LAN IP ---
# Create a dummy socket to find the local IP
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    # Connect to a public DNS server (doesn't send any real data)
    s.connect(("8.8.8.8", 80))
    # Get the socket's own address
    local_ip = s.getsockname()[0]
    s.close()
except Exception as e:
    local_ip = "Could not determine"
    print(f"Error getting local IP: {e}")

# --- Get Public/WAN IP ---
# Use an external service to find the public IP
try:
    wan_ip = urllib.request.urlopen('https://api.ipify.org').read().decode('utf8')
except Exception as e:
    wan_ip = "Could not determine"
    print(f"Error getting WAN IP: {e}")


# --- Print the IP addresses ---
print(f"Your Local/LAN IP is: {local_ip}")
print(f"Your Public/WAN IP is: {wan_ip}")
