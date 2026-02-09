#!/bin/bash

# Copyright (c) 2024-2025 Rámon van Raaij

# License: MIT

# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu

# install_djbdns.sh - This script installs djbdns, a custom DNS server, on AlmaLinux 9. It first checks if the script is run as root and the system is compatible. Then, it disables SELinux (with user confirmation) and installs required packages. Finally, it sets up djbdns with user-provided information like IP addresses and upstream DNS servers. The script concludes by suggesting a system reboot and further configuration steps.

# Only for AlmaLinux 9

# Check if the script is run as root
if [[ ! $(id -u) -eq 0 ]]; then
  echo "Error: This script must be run as root."
  exit 1
fi

# Check if the system is an AlmaLinux 9.x release
os_version=$(rpm -q --queryformat "%{version}" -qf /etc/redhat-release)

# Use pattern matching: checks if $os_version is "9" or starts with "9."
if [[ ! ($os_version == "9" || $os_version == 9.*) ]]; then
  echo "Error: This script is only compatible with AlmaLinux 9."
  echo "Detected version: $os_version"
  exit 1
fi

echo "AlmaLinux 9 detected. Proceeding..."

## Setting up custom DNS cache:

# This script requires disabling SELinux. Are you sure you want to proceed? (y/N)
echo "This script requires disabling SELinux. Are you sure you want to proceed? (y/N)"
read -r disable_selinux
if [[ ! $disable_selinux =~ ^[Yy]$ ]]; then
  echo "Exiting script. Please disable SELinux if you want to continue."
  exit 1
fi

# Disable SELinux if the user confirmed
if [[ $disable_selinux =~ ^[Yy]$ ]]; then
  setenforce 0
  sed -i 's/^SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
fi

# Installing required packages
yum install chkconfig wget make

# Define the base URL for package downloads
base_url="https://updates.interworx.com/interworx/8/base/RPMS/9Server/x86_64/"

# Define package names
packages=(ucspi-tcp daemontools djbdns)

# Loop through each package
for package in "${packages[@]}"; do
  # Download package list page
  package_list=$(wget -qO- "${base_url}")

  # Extract the latest version using regular expression (adjust as needed)
  latest_version=$(echo "$package_list" | grep -Eo "${package}-[0-9]+\.[0-9]+-[0-9]+" | tail -n 1)

  # Check if a version was found
  if [[ -z "$latest_version" ]]; then
    echo "Error: Could not find latest version for $package."
    continue
  fi

  # Download the latest package
  wget "${base_url}${latest_version}.rhe9x.iworx.x86_64.rpm"

  echo "Downloaded: ${base_url}${latest_version}.rhe9x.iworx.x86_64.rpm"
done

# Installing downloaded packages
yum install ./*.rpm

# This part of the script creates the systemd service unit for svscan.
# Define the path for the new service file
SERVICE_FILE="/etc/systemd/system/svscan.service"

echo "Creating systemd service file for svscan at ${SERVICE_FILE}..."

# The 'EOF' delimiter is quoted to prevent shell expansion of any characters like $ inside the block.
cat << 'EOF' > "${SERVICE_FILE}"
[Unit]
Description=daemontools Service Supervisor (svscan)
Documentation=http://cr.yp.to/daemontools/svscan.html
After=local-fs.target

[Service]
# The command to start svscan, telling it to manage the /service directory.
ExecStart=/usr/bin/svscan /service

# Restart the service automatically if it fails.
# This is critical for a supervisor process.
Restart=on-failure
RestartSec=5s

# Standard output and error will go to the systemd journal.
StandardOutput=journal
StandardError=journal

[Install]
# This makes it part of the default boot target, ensuring it starts on boot.
WantedBy=multi-user.target
EOF

# Check if the file was created successfully
if [ $? -eq 0 ]; then
    # Set appropriate permissions for the service file
    chmod 644 "${SERVICE_FILE}"
    echo "Successfully created and configured ${SERVICE_FILE}"
    echo ""
    echo "--------------------------------------------------------"
    echo "IMPORTANT: Now you must reload systemd and enable the service:"
    echo "--------------------------------------------------------"
    echo "1. sudo systemctl daemon-reload"
    echo "2. sudo systemctl enable svscan.service"
    echo "3. sudo systemctl start svscan.service"
    echo ""
    echo "You can check its status with: systemctl status svscan.service"
    echo ""
else
    echo "Error: Failed to create ${SERVICE_FILE}" >&2
    exit 1
fi

# Enabling and starting djbdns service
sudo systemctl daemon-reload
sudo systemctl enable --now svscan.service

# Check if svscan is running
if ! ps -A | grep -q svscan; then
  echo "Error: svscan is not running."
  exit 1
fi

# This part of the script creates the systemd service unit for djbdns.
# It must be run with root privileges (e.g., using sudo) to write to /etc/systemd/system/.

# Define the path for the new service file
SERVICE_FILE="/etc/systemd/system/djbdns.service"

echo "Creating systemd service file for djbdns at ${SERVICE_FILE}..."

# The 'EOF' delimiter is quoted to prevent shell expansion of any characters like $ inside the block.
cat << 'EOF' > "${SERVICE_FILE}"
[Unit]
Description=djbdns (tinydns, axfrdns, dnscache) via daemontools
Documentation=https://cr.yp.to/djbdns.html
After=network.target
# If you have a service file for svscan itself, it's good practice to require it:
Requires=svscan.service
After=svscan.service

[Service]
Type=oneshot
RemainAfterExit=yes

# The /bin/sh -c wrapper is needed to handle the shell globbing (*)
ExecStart=/bin/sh -c '/usr/bin/svc -u /service/dnscache /service/tinydns /service/axfrdns'
ExecStop=/bin/sh -c '/usr/bin/svc -d /service/dnscache /service/tinydns /service/axfrdns'
ExecReload=/bin/sh -c '/usr/bin/svc -t /service/dnscache /service/tinydns /service/axfrdns'

[Install]
WantedBy=multi-user.target
EOF

# Check if the file was created successfully
if [ $? -eq 0 ]; then
    # Set appropriate permissions for the service file
    chmod 644 "${SERVICE_FILE}"
    echo "Successfully created and configured ${SERVICE_FILE}"
    echo ""
    echo "--------------------------------------------------------"
    echo "IMPORTANT: Now you must reload systemd and enable the service:"
    echo "--------------------------------------------------------"
    echo "1. sudo systemctl daemon-reload"
    echo "2. sudo systemctl enable djbdns.service"
    echo "3. sudo systemctl start djbdns.service"
    echo ""
else
    echo "Error: Failed to create ${SERVICE_FILE}" >&2
    exit 1
fi

# Enabling and starting djbdns service
sudo systemctl daemon-reload
sudo systemctl enable --now djbdns.service

# Setting local nameserver
echo "nameserver 127.0.0.1" > /etc/resolv.conf
cat /etc/resolv.conf

# Testing connectivity with ping (replace google.nl if needed)
if ! ping -c 2 google.nl &> /dev/null; then
  echo "Error: Ping to google.nl timed out. Check your network connection and try again."
  exit 1
fi

## Creating a DNS server:

# Cleaning up previous configuration
rm -rf /var/djbdns/tinydns
rm -f /service/tinydns
rm -rf /var/djbdns/axfrdns
rm -f /service/axfrdns

# Enter the IP address of this DNS server:
read -p "Enter the IP address of this DNS server: " dns_server_ip

# Validate entered IP address
while ! [[ $dns_server_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; do
  echo "Invalid IP address. Please enter a valid IPv4 address."
  read -p "Enter the IP address of this DNS server: " dns_server_ip
done

# Configure tinydns
tinydns-conf tinydns dnslog /var/djbdns/tinydns $dns_server_ip

# Link tinydns service
ln -s /var/djbdns/tinydns /service/

# Configure axfrdns
axfrdns-conf axfrdns dnslog /var/djbdns/axfrdns /var/djbdns/tinydns $dns_server_ip

# Enter the IP address of the first upstream DNS server:
read -p "Enter the IP address of the first upstream DNS server: " upstream_dns1_ip

# Validate entered IP address (same as above)
while ! [[ $upstream_dns1_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; do
  echo "Invalid IP address. Please enter a valid IPv4 address."
  read -p "Enter the IP address of the first upstream DNS server: " upstream_dns1_ip
done

# Configure upstream DNS server in axfrdns
echo "$upstream_dns1_ip:allow" > /var/djbdns/axfrdns/tcp

# Optionally enter the IP address of a second upstream DNS server (repeat validation)
read -p "Enter the IP address of a second upstream DNS server (optional): " upstream_dns2_ip
if [[ -n "$upstream_dns2_ip" ]]; then
  while ! [[ $upstream_dns2_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; do
    echo "Invalid IP address. Please enter a valid IPv4 address."
    read -p "Enter the IP address of the second upstream DNS server: " upstream_dns2_ip
  done
  echo "$upstream_dns2_ip:allow" >> /var/djbdns/axfrdns/tcp
fi

# Generate axfrdns configuration
cd /var/djbdns/axfrdns/
make

# Link axfrdns service
ln -s /var/djbdns/axfrdns /service/

# Restarting djbdns service
systemctl restart djbdns.service

echo "The djbdns setup and configuration is complete."
echo "If there were no errors, please reboot the system."
echo "After the reboot, you can proceed with setting up synchronization."
