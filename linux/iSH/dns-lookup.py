#!/usr/bin/env python3
# dns-lookup.py
# =================================================================
# DNS Lookup Tool
# Copyright (c) 2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
# =================================================================
# This script performs a DNS lookup for a given domain name to find
# its A records (IPv4 addresses).
#
# It performs the following actions:
# 1. Accepts a domain name as a command-line argument.
# 2. Queries the Google Public DNS (DoH) API for A records.
# 3. Parses the JSON response from the API.
# 4. Prints the corresponding IP addresses to the terminal.
# 5. Includes basic error handling for network issues.
#
# Usage:
# Run the script from your terminal: python3 dns-lookup.py <domain_name>
# Example: python3 dns-lookup.py google.com
# =================================================================

import requests
import json
import sys

# Check if a domain name is provided
if len(sys.argv) < 2:
    print("Usage: python3 dns-lookup.py <domain_name>")
    sys.exit(1)

domain_name = sys.argv[1]
url = f"https://dns.google/resolve?name={domain_name}&type=A"

try:
    response = requests.get(url)
    response.raise_for_status()  # Raise an exception for bad status codes (4xx or 5xx)
    data = response.json()

    if 'Answer' in data:
        print(f"IP addresses for {domain_name}:")
        for answer in data['Answer']:
            if answer.get('type') == 1: # Type 1 is for A records
                print(f"- {answer.get('data')}")
    else:
        print(f"No A records found for {domain_name}")

except requests.exceptions.RequestException as e:
    print(f"An error occurred: {e}")
except json.JSONDecodeError:
    print("Failed to decode the response from the server.")
