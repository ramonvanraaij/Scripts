# My Personal Scripts Collection

This repository is a curated collection of personal scripts designed for various system administration and automation tasks. The scripts are primarily written in Bash and Python, focusing on Linux environments.

**Please note:** This is a personal project and a work in progress. Not all scripts are actively maintained, and some of my scripts may not be included here yet.

## Features

*   **System Automation:** Scripts to automate daily tasks like system updates for Arch Linux (including AUR), and other distributions.
*   **Backups:** Robust backup solutions for WordPress sites (database and files), and a generic `rsync`-to-Git backup script.
*   **Security:** Tools to enhance security, such as automatically updating Nginx's trusted proxy list for Cloudflare.
*   **Utilities:** A variety of helper scripts for tasks like DNS lookups, file synchronization, and more.

## Directory Structure

The repository is organized to be clear and easy to navigate:

```
/
├── .gitignore
├── LICENSE.md
├── README.md
└── linux
    ├── AlmaLinux
    │   ├── install_djbdns.sh
    │   └── install_dnf-automatic.sh
    ├── Alpine Linux
    │   ├── apk-autoupdate-cron
    │   ├── example_restic-b2.env
    │   ├── example_restic-sftp.env
    │   └── restic_backup.sh
    ├── Arch Linux
    │   ├── 00-runonce.sh
    │   ├── add-repo_chaotic-aur.sh
    │   ├── fix_ocamlfuse_upgrade.sh
    │   ├── GRUB_Recovery_Arch_Windows_DualBoot.md
    │   ├── install_qnap-qsync.sh
    │   ├── install_Snap_Store.sh
    │   ├── plymouth_boot_splash.md
    │   └── system-update.sh
    ├── backup.sources
    ├── backup-to-git.py
    ├── backup_wordpress.sh
    ├── cloudflare
    │   └── cloudflare-cache-purge.sh
    ├── Debian
    │   └── install_qnap-qsync.sh
    ├── Distrobox
    │   ├── create_debian.sh
    │   └── create_pod.sh
    ├── install_homebrew.sh
    ├── iSH
    │   ├── config.fish
    │   ├── dns-lookup.py
    │   └── get-my-ip.py
    ├── nginx
    │   ├── clear_nginx_cache.sh
    │   ├── configure_gzip.sh
    │   ├── update-cloudflare-ips.sh
    │   └── wordpress_update.sh
    ├── Proxmox
    │   └── update-proxmox-cloudflare-ips.sh
    ├── Proxmox Mail Gateway
    │   ├── pmg_backup.md
    │   └── pmg_backup.sh
    ├── proxy-browser.sh
    └── sshjump.sh
```

*   `linux/`: Contains all scripts, categorized by the target Linux distribution or application.
*   `*.sh`: Bash scripts for various tasks.
*   `*.py`: Python scripts for more complex logic.

## Getting Started

To use any of these scripts, you can clone this repository and then execute the desired script. Most scripts include a documentation header explaining their specific usage, configuration, and any dependencies.

For example, to use the Arch Linux system update script:

```bash
chmod +x linux/Arch\ Linux/system-update.sh
./linux/Arch\ Linux/system-update.sh
```

Please read the comments at the beginning of each script for detailed instructions.

## Disclaimer

These scripts are provided "as is" without warranty of any kind, express or implied. The author is not liable for any damages arising from the use of these scripts.

## License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details.

## Copyright

Copyright (c) 2024-2025 Rámon van Raaij