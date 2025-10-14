# Fixing GRUB Bootloader on Arch Linux (Dual Boot with Windows)

This guide provides a step-by-step process to restore the GRUB bootloader on an Arch Linux system, particularly in a dual-boot setup with Windows 11 Pro, after Windows updates may have overwritten or corrupted the GRUB entry.

## Scenario

This guide is applicable when:
*   You have a dual-boot system with Arch Linux and Windows 11 Pro.
*   Windows 11 Pro updates have caused your system to boot directly into Windows, bypassing GRUB.
*   Your Arch Linux installation uses LUKS encryption for the root partition and BTRFS subvolumes (`@` for root, `@home` for home).

## Prerequisites

*   An Arch Linux Live USB/CD to boot into a recovery environment.
*   Basic understanding of Linux command-line operations.

## Recovery Steps

Boot your system using the Arch Linux Live environment. Once booted, open a terminal and follow these steps:

### 1. Identify Your Partitions

First, list all available block devices and their partitions to identify your Arch Linux and EFI system partitions.

```bash
lsblk -p
```

*   **Identify your LUKS-encrypted root partition:** In this example, we assume it's `/dev/nvme0n1p5`.
*   **Identify your EFI system partition (ESP):** In this example, we assume it's `/dev/nvme0n1p1`.

### 2. Unlock LUKS-Encrypted Root Partition

If your Arch Linux root partition is encrypted with LUKS, you need to unlock it. Replace `/dev/nvme0n1p5` with your actual LUKS partition.

```bash
cryptsetup open /dev/nvme0n1p5 root
```
You will be prompted to enter your LUKS passphrase. Upon successful verification, a mapping named `root` will be created under `/dev/mapper/`.

### 3. Mount Arch Linux Filesystem

Now, mount your Arch Linux root filesystem and other necessary partitions.

#### Create a temporary mount point:

```bash
mkdir /mnt/rootfs
```

#### Mount the BTRFS root subvolume (`@`):

Assuming your BTRFS root subvolume is named `@` and is on the `root` LUKS mapping:

```bash
mount -t btrfs /dev/mapper/root -o subvol=@ /mnt/rootfs
```

#### Mount the BTRFS home subvolume (`@home`) (Optional):

If you have a separate `@home` subvolume, mount it:

```bash
mkdir /mnt/rootfs/home
mount -t btrfs /dev/mapper/root -o subvol=@home /mnt/rootfs/home
```

#### Mount the EFI System Partition (ESP):

Mount your EFI system partition to `/mnt/rootfs/boot`. Replace `/dev/nvme0n1p1` with your actual EFI partition.

```bash
mount -t vfat /dev/nvme0n1p1 /mnt/rootfs/boot
```

### 4. Chroot into Your Arch Linux Installation

Change the root directory to your mounted Arch Linux installation to perform system-level operations.

```bash
arch-chroot /mnt/rootfs/
```

### 5. Reinstall and Configure GRUB

Inside the chroot environment, reinstall GRUB and generate its configuration file.

#### Install GRUB to the EFI System Partition:

This command installs the GRUB EFI bootloader.

```bash
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck
```
*   `--target=x86_64-efi`: Specifies the target architecture for EFI systems.
*   `--efi-directory=/boot`: Points to the mounted EFI system partition.
*   `--bootloader-id=GRUB`: Sets the name of the GRUB bootloader entry in the UEFI firmware.
*   `--recheck`: Recheck device map.

#### Generate GRUB Configuration File:

This command scans for operating systems and generates the `grub.cfg` file.

```bash
grub-mkconfig -o /boot/grub/grub.cfg
```

### 6. (Optional) Adjust Windows Boot Entry Name

Sometimes, after `grub-mkconfig`, the Windows boot entry might appear with a generic name. You can edit `grub.cfg` to change it to something more descriptive like 'Windows 11 Pro'.

```bash
nano /boot/grub/grub.cfg
```
Search for the Windows entry and modify its title.

### 7. Exit Chroot and Reboot

Exit the chroot environment and reboot your system.

```bash
exit
```

```bash
reboot
```

Your system should now boot into GRUB, allowing you to select between Arch Linux and Windows 11 Pro.
