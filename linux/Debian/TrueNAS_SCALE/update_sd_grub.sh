#!/usr/bin/env bash
# update_sd_grub.sh
# =================================================================
# TrueNAS SD Card Boot Automation Script
#
# Copyright (c) 2026 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script automatically updates the Legacy GRUB bootloader on the 
# internal SD card for the HP MicroServer Gen8 SD-to-ODD boot workaround.
# It detects the current active Boot Environment and kernel, ensuring
# the system successfully boots after TrueNAS updates.
#
# Usage:
# Run automatically via TrueNAS Init/Shutdown scripts, or manually:
# sudo /root/update_sd_grub.sh
# =================================================================

set -o errexit -o nounset -o pipefail

SD_DEV="/dev/sdd1"
MOUNT_POINT="/mnt/sd_boot"

# Detect current Boot Environment from zpool
CURRENT_BE=$(zpool get bootfs boot-pool | awk 'NR==2 {print $3}' | cut -d'/' -f3)

# Detect current Kernel version
KERNEL_VER=$(uname -r)

echo "Starting TrueNAS SD Card GRUB update..."
echo "Detected Active Boot Environment: ${CURRENT_BE}"
echo "Detected Active Kernel: ${KERNEL_VER}"

mkdir -p "${MOUNT_POINT}"

# Check if SD device exists
if [ ! -b "${SD_DEV}" ]; then
    echo "Error: SD card device ${SD_DEV} not found!"
    exit 1
fi

mount "${SD_DEV}" "${MOUNT_POINT}"

# Ensure unmount on exit or failure
trap 'sync; umount "${MOUNT_POINT}"' EXIT

# Backup the last working configuration
if [ -f "${MOUNT_POINT}/boot/grub/grub.cfg" ]; then
    echo "Backing up existing grub.cfg to grub.cfg.bak..."
    cp "${MOUNT_POINT}/boot/grub/grub.cfg" "${MOUNT_POINT}/boot/grub/grub.cfg.bak"
fi

echo "Writing new grub.cfg..."

cat << EOF > "${MOUNT_POINT}/boot/grub/grub.cfg"
set timeout=5
set default=0

insmod part_gpt
insmod zfs

menuentry "TrueNAS SCALE (Auto-Updated: ${CURRENT_BE})" {
    # Find the disk by name, regardless of the port number
    search --no-floppy --label boot-pool --set=root
    
    echo "Loading the TrueNAS SCALE kernel..."
    linux /ROOT/${CURRENT_BE}@/boot/vmlinuz-${KERNEL_VER} root=ZFS=boot-pool/ROOT/${CURRENT_BE} ro console=tty1 boot=zfs
    initrd /ROOT/${CURRENT_BE}@/boot/initrd.img-${KERNEL_VER}
}

menuentry "TrueNAS SCALE (Fallback / Previous)" {
    configfile /boot/grub/grub.cfg.bak
}
EOF

echo "GRUB update successful."
