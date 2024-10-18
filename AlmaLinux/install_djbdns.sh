#!/bin/bash

# Only for AlmaLinux 9

# Check if the script is run as root
if [[ ! $(id -u) -eq 0 ]]; then
  echo "Error: This script must be run as root."
  exit 1
fi

# Check if the system is AlmaLinux 9
if [[ $(rpm -q --queryformat "%{version}" -qf /etc/redhat-release) != "9" ]]; then
  echo "Error: This script is only compatible with AlmaLinux 9."
  exit 1
fi

## Setting up custom DNS cache:

# This script requires disabling SELinux. Are you sure you want to proceed? (y/N)
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
yum install chkconfig rsync wget

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

# Enabling and starting djbdns service
chkconfig --add djbdns
chkconfig djbdns on
sh -cf '/bin/svscanboot &'

# Restarting djbdns service
service djbdns restart

# Check if svscan is running
if ! ps -A | grep -q svscan; then
  echo "Error: svscan is not running."
  exit 1
fi

# Setting local nameserver
echo "nameserver 127.0.0.1" > /etc/resolv.conf
cat /etc/resolv.conf

# Testing connectivity with ping (replace google.nl if needed)
if ! ping -c 2 google.nl &> /dev/null; then
  echo "Error: Ping to google.nl timed out. Check your network connection and try again."
  exit 1
fi

# Adding djbdns startup script to rc.local
echo "sh -cf '/bin/svscanboot &'" >> /etc/rc.d/rc.local
chmod +x /etc/rc.d/rc.local

## Creating a DNS server:

# Cleaning up previous configuration
rm -rf /var/djbdns/tinydns
rm -f /service/tinydns

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

echo "The djbdns setup and configuration is complete."
echo "If there were no errors, please reboot the system."
echo "After the reboot, you can proceed with setting up synchronization."
