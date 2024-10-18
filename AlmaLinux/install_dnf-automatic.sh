#!/bin/bash

# Install dnf-automatic
sudo dnf install dnf-automatic

# Configure dnf-automatic
sudo sed -i 's/apply_updates = no/apply_updates = yes/g' /etc/dnf/automatic.conf
sudo sed -i 's/reboot = never/reboot = when-needed/g' /etc/dnf/automatic.conf

# Enable and start dnf-automatic
sudo systemctl enable --now dnf-automatic.timer

# List timers for dnf-automatic
sudo systemctl list-timers dnf-*
