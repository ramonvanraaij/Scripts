# My Personal Scripts Collection

This repository is a curated collection of personal scripts designed for various system administration and automation tasks. The scripts are primarily written in Bash and Python, focusing on Linux environments.

**Please note:** This is a personal project and a work in progress. Not all scripts are actively maintained, and some of my scripts may not be included here yet.

## Features

The scripts are designed to be modular and configurable, with clear instructions for usage and automation. They often include features like:

*   **Automated Updates:** Scripts for updating system packages and applications.
*   **Backups:** Scripts for backing up websites, databases, and configuration files.
*   **Security:** Scripts for managing firewall rules and trusted proxies.
*   **Utility:** Various helper scripts for tasks like DNS lookups and file synchronization.

## Dependencies

Many scripts in this repository rely on common command-line tools. Please ensure the following are installed on your system:

*   `curl`: For making HTTP requests.
*   `jq`: For parsing JSON data.
*   `rsync`: For file synchronization.
*   `git`: For version control.

## Secrets Management

Scripts that require sensitive information, such as API keys or passwords, will have placeholders in the script itself. For example, in `cloudflare-cache-purge.sh`, you will find:

```bash
CLOUDFLARE_API_TOKEN="YOUR_API_TOKEN"
```

It is recommended to replace these placeholders with a secure method of secrets management, such as environment variables or a dedicated secrets management tool.

## Directory Structure

The repository is organized as follows:

*   `linux/`: Contains scripts for various Linux distributions and applications.
    *   `AlmaLinux/`, `Alpine Linux/`, `Arch Linux/`, `Debian/`: Distribution-specific scripts.
    *   `Distrobox/`, `iSH/`, `nginx/`, `Proxmox/`, `Proxmox Mail Gateway/`: Application-specific scripts.
    *   `backup_wordpress.sh`, `backup-to-git.py`: General-purpose backup scripts.
*   `.gitignore`: Excludes common temporary files, packages, and logs.
*   `LICENSE.md`: The MIT License for the repository.
*   `README.md`: A brief introduction to the script collection.

## Key Scripts

Here are some of a few key scripts in this collection:

*   **`linux/Arch Linux/system-update.sh`**: Automates daily system updates on Arch Linux, including `pacman` and `yay` packages, and pulls updates for local git repositories.
*   **`linux/backup_wordpress.sh`**: A comprehensive script for backing up a WordPress site, including the database and files. It supports remote backups, rotation, and email notifications.
*   **`linux/nginx/update-cloudflare-ips.sh`**: Automatically updates Nginx's trusted proxy list for Cloudflare IPs to ensure correct IP address resolution.
*   **`linux/backup-to-git.py`**: A Python script that uses `rsync` to back up files and directories to a local Git repository and pushes the changes to a remote repository.
*   **`linux/iSH/dns-lookup.py`**: A simple Python script for performing DNS 'A' record lookups using Google's DNS-over-HTTPS service.
*   **`linux/cloudflare/cloudflare-cache-purge.sh`**: A script to purge the Cloudflare cache for a specific zone, with support for both interactive and non-interactive (flag-based) operation.

## Getting Started

To use any of these scripts, you can clone this repository and then execute the desired script. Most scripts include a documentation header explaining their specific usage, configuration, and any dependencies.

For example, to use the Arch Linux system update script:

```bash
chmod +x linux/Arch\ Linux/system-update.sh
./linux/Arch\ Linux/system-update.sh
```

Please read the comments at the beginning of each script for detailed instructions.

## Development Conventions

*   **Shell Scripts:** Scripts are written in Bash and are designed to be POSIX-compliant where possible. They use `set -o errexit -o nounset -o pipefail` for robustness. All scripts must be compatible with the strict Alpine Linux BusyBox shell.
*   **Python Scripts:** Scripts are written in Python 3 and use standard libraries where possible.
*   **Commenting:** Scripts should be well-commented to ensure clarity and maintainability. The preferred commenting style includes:
    *   **Header:** A comprehensive header at the beginning of each script with the following sections:
        *   Shebang (e.g., `#!/usr/bin/env bash`)
        *   Script name
        *   A descriptive title
        *   Copyright and License information
        *   Author information
        *   A detailed description of the script's purpose, features, and usage with examples.
    *   **Section comments:** Use comments to divide the script into logical sections (e.g., `--- Configuration ---`, `--- Core Functions ---`).
    *   **Function comments:** Add a comment above each function explaining its purpose and parameters.
    *   **In-line comments:** Use in-line comments to explain complex or non-obvious lines of code.

## Troubleshooting

*   **Script execution errors:** Ensure that the scripts in `~/.local/bin` are executable (`chmod +x <script>`).
*   **Missing dependencies:** If a script fails due to a missing command, please install the required dependency using your system's package manager.
*   **Backup script failures:** If a backup script fails, check the script's log output for any error messages from the underlying tools (e.g., `rsync`, `mysqldump`).

## Disclaimer

These scripts are provided "as is" without warranty of any kind, express or implied. The author is not liable for any damages arising from the use of these scripts.

## License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details.

## Copyright

Copyright (c) 2024-2025 Rámon van Raaij