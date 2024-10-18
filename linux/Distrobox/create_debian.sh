#!/bin/bash

# dependencies: wget, jq

# Set a variable for the pod name (optional)
POD_NAME="debian"

# Create a Debian pod with the latest version
distrobox create -i debian:latest -n "${POD_NAME:-debian}"

# Wait for the pod to be ready (adjust the timeout as needed)
#timeout 120 distrobox enter "${POD_NAME}" -- true || {
#  echo "Error: Pod creation timed out."
#  exit 1
#}
distrobox enter "${POD_NAME}" -- true

# Update and enter the pod
distrobox upgrade "${POD_NAME}"
distrobox enter "${POD_NAME}" -- sudo apt -y update

# Install default packages
distrobox enter "${POD_NAME}" -- sudo apt -y install bat fish ugrep exa htop wget

# Create a symbolic link for batcat
distrobox enter "${POD_NAME}" --  sudo ln -s /usr/bin/batcat /usr/bin/bat

# Download and install the latest fastfetch release
FASTFETCH_VERSION=$(curl -s https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest | jq -r '.tag_name')
distrobox enter "${POD_NAME}" -- wget -O fastfetch.deb https://github.com/fastfetch-cli/fastfetch/releases/download/$FASTFETCH_VERSION/fastfetch-linux-amd64.deb
distrobox enter "${POD_NAME}" -- sudo dpkg -i fastfetch.deb

# Clean up downloaded file (optional)
# Uncomment the following line to remove the downloaded deb after installation
# rm fastfetch.deb

echo "Debian pod '${POD_NAME}' set up with default tools and fastfetch."
