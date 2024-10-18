#!/bin/bash

# Copyright (c) 2024 Rámon van Raaij

# License: MIT

# Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu

# install_dnf-automatic.sh - This script automates security updates on a system using  dnf-automatic. It first installs the dnf-automatic package. Then, it edits the configuration file (/etc/dnf/automatic.conf) to enable automatic updates and reboots when necessary. Finally, it enables and starts the dnf-automatic service and lists all timers related to it for verification.

# Install dnf-automatic
sudo dnf install dnf-automatic

# Configure dnf-automatic
sudo sed -i 's/apply_updates = no/apply_updates = yes/g' /etc/dnf/automatic.conf
sudo sed -i 's/reboot = never/reboot = when-needed/g' /etc/dnf/automatic.conf

# Enable and start dnf-automatic
sudo systemctl enable --now dnf-automatic.timer

# List timers for dnf-automatic
sudo systemctl list-timers dnf-*
