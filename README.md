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
├── linux/
│   ├── AlmaLinux/
│   ├── Alpine Linux/
│   ├── Arch Linux/
│   ├── Debian/
│   ├── Distrobox/
│   ├── iSH/
│   ├── nginx/
│   ├── Proxmox/
│   └── Proxmox Mail Gateway/
├── .gitignore
├── LICENSE.md
└── README.md
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