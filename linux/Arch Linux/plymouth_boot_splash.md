# Plymouth Boot Splash on Arch Linux

This guide outlines the steps to enable and configure the Plymouth boot splash on an Arch Linux system.

## Prerequisites

Ensure you have a working Arch Linux installation.

## Installation Steps

Follow these steps to get Plymouth up and running:

1.  **Install Plymouth:**
    Install the `plymouth` package using `pacman`:
    ```bash
    sudo pacman -S plymouth
    ```

2.  **Edit `mkinitcpio.conf`:**
    Open the `/etc/mkinitcpio.conf` file and add `plymouth` to the `HOOKS` array. The order of hooks can be important; `plymouth` should generally come before `filesystems` and `fsck`.

    Example of `HOOKS` array:
    ```
    HOOKS=(base udev autodetect keyboard keymap consolefont block filesystems fsck plymouth)
    ```

3.  **Rebuild the Initramfs:**
    After modifying `mkinitcpio.conf`, you need to rebuild your initramfs:
    ```bash
    sudo mkinitcpio -P
    ```

4.  **Edit GRUB Configuration (if using GRUB):**
    If you are using GRUB as your bootloader, edit the `/etc/default/grub` file. Locate the `GRUB_CMDLINE_LINUX_DEFAULT` line and add `splash quiet` to it.

    Example:
    ```
    GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet splash"
    ```

5.  **Update GRUB:**
    After modifying the GRUB configuration, update GRUB to apply the changes:
    ```bash
    sudo grub-mkconfig -o /boot/grub/grub.cfg
    ```

6.  **Reboot:**
    Finally, reboot your system to see the Plymouth boot splash in action:
    ```bash
    sudo reboot
    ```

## Troubleshooting

*   **Plymouth not showing:**
    *   Verify that your graphics drivers are correctly installed and configured.
    *   Ensure that `plymouth` is correctly added to the `HOOKS` array in `mkinitcpio.conf` and that the initramfs was rebuilt.
    *   Check your GRUB configuration for `splash quiet` and ensure GRUB was updated.

*   **Checking Plymouth logs:**
    If you encounter issues, check the Plymouth logs for errors:
    ```bash
    journalctl -b -u plymouth
    ```
