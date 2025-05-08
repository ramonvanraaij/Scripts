# Fix GRUB bootloader
## On a dual boot Arch Linux / Windows 11 Pro system
This is used after Windows 11 Pro updates the boatloader and breaks GRUB.

### List information about all available block devices
`lsblk -p`
### Open the LUKS device `/dev/nvme0n1p5` and sets up a mapping `root` aftersuccessful verification of the supplied passphrase.
`cryptsetup open /dev/nvme0n1p5 root`
### Create the directory `/mnt/rootfs`
`mkdir /mnt/rootfs`
### Mount the BTRFS subvolume `@`
`mount -t btrfs /dev/mapper/root -o subvol=@ /mnt/rootfs`
### Mount the BTRFS subvolume `@home`
`mount -t btrfs /dev/mapper/root -o subvol=@home /mnt/rootfs/home`
### Mount the VFAT boot partition
`mount -t vfat /dev/nvme0n1p1 /mnt/rootfs/boot`
### Chroot in `/mnt/rootfs/`
`arch-chroot /mnt/rootfs/`
### Copy GRUB image into `/boot/grub`
`grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB`
### Generate the configuration file for GRUB
`grub-mkconfig -o /boot/grub/grub.cfg`
### Change the Windows entry to 'Windows 11 Pro'
`nano /boot/grub/grub.cfg`
### Exit chroot and reboot
`exit`

`reboot`
