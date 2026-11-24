# **How to Use the Proxmox Mail Gateway Backup Script**

This guide provides step-by-step instructions to configure and automate the pmg_backup.sh script for your Proxmox Mail Gateway.

### **1. Prerequisites**

Before you begin, ensure the necessary tools are installed on your Proxmox Mail Gateway server.

* `rsync`: Required if you plan to sync backups to a remote server (`RSYNC_ENABLED="true"`).
* `sendmail`: Comes with the PMG postfix installation (`/usr/sbin/sendmail`). Required for email notifications (`EMAIL_ENABLED="true"`).

You can install them using the following command:
```bash
apt-get update && apt-get install rsync
```

`mailutils` is no longer needed; email is sent directly with `sendmail -t`.

### **2. Save the Script**

Save the script content to a file on your PMG server. A common and recommended location is `/usr/local/bin/`.

```bash
# For example, create and edit the file with nano:
nano /usr/local/bin/pmg_backup.sh

# Paste the script content into the editor and save the file.
```

### **3. Install the Script**

Install the script with root ownership and execute permission:

```bash
install -m 0700 -o root -g root pmg_backup.sh /usr/local/bin/pmg_backup.sh
```

### **4. Configure the Script**

Settings come from a root-owned configuration file at `/etc/pmg_backup.conf` (or the path given with `--config`), not from edits to the script. The precedence is: built-in default, then the environment, then the config file, which wins.

Create `/etc/pmg_backup.conf` with the settings you want to change:

```bash
MAX_BACKUPS=5
BACKUP_DIR=/var/lib/pmg/backup
RSYNC_ENABLED=true
REMOTE_HOST=your.server.com
REMOTE_USER=backup
REMOTE_DIR=/path/to/remote/backups
REMOTE_SSH_KEY=/root/.ssh/id_ed25519
REMOTE_MAX_BACKUPS=90
EMAIL_ENABLED=true
EMAIL_ON_SUCCESS=false
FROM_ADDRESS="PMG Backup <noreply@example.com>"
RECIPIENT_ADDRESS=admin@example.com
SENDMAIL_CMD=/usr/sbin/sendmail
LOG_FILE=/var/log/pmg_backup.log
LOG_TAIL_LINES=200
PMGBACKUP_CMD=pmgbackup
RSYNC_CMD=rsync
SSH_CMD=ssh
```

Make it root-owned and readable only by root:

```bash
chown root:root /etc/pmg_backup.conf
chmod 600 /etc/pmg_backup.conf
```

A missing config file is fine unless `--config` names it. A symlink, a non-regular file, a file not owned by uid 0, a group- or world-writable file, or a file with a bash syntax error is refused.

### **5. Set Up SSH Key Authentication (Crucial for Automation)**

For the script to run automatically without asking for a password, you must set up passwordless SSH login from your PMG server to your backup server.

1. **On your PMG server**, generate an SSH key if you don't already have one:
```bash
   ssh-keygen -t ed25519
   # Press Enter to accept the default file location and options.
```

2. **Copy the public key** to your remote backup server. Replace backup and your.server.com with your remote user and host:
```bash
   ssh-copy-id -i /root/.ssh/id_ed25519.pub backup@your.server.com
```
This command will ask for the remote user's password one last time.

### **6. Test the Script**

Run the script manually from the command line to ensure everything is working correctly:

```bash
/usr/local/bin/pmg_backup.sh
```

A failed run sends one failure email; a successful run is silent unless `EMAIL_ON_SUCCESS=true`.

To test email delivery without running a backup:

```bash
/usr/local/bin/pmg_backup.sh --test-email
```

Check the console output and `/var/log/pmg_backup.log` for any errors.

### **7. Behaviour**

* A failing run sends exactly one failure email naming the step that failed.
* A successful run is silent unless `EMAIL_ON_SUCCESS=true`, in which case exactly one success email is sent.
* `--test-email` sends exactly one test email and runs no backup, rsync or ssh.
* A failing `--test-email` run prints an error message, exits 1, and sends no email (the failure email is suppressed because `NOTIFICATION_SENT` is already set).
* Exit codes: 0 on success; 1 on a validation, config or rotation failure; 2 on a usage error; the failing command's own exit code for pmgbackup, rsync and the remote rotation; 129/130/143 when the run is ended by a HUP/INT/TERM signal. A signal ends the run with that exit code, and the failure email is sent only if bash gets to run its EXIT trap.
* An rsync failure or a remote rotation failure counts as a failure; the local backup stays.
* `EMAIL_ENABLED=false` sends no failure or success email; `--test-email` still sends its test email.
* With `RSYNC_ENABLED=false`, only the local backup and rotation run.

### **8. Schedule with Cron**

Once you've confirmed the script runs successfully, schedule it to run automatically using cron:

```bash
0 2 * * * /usr/local/bin/pmg_backup.sh >/dev/null 2>&1
```

Output goes to `/var/log/pmg_backup.log` and to the failure email.

### **9. Log Rotation**

Rotate `/var/log/pmg_backup.log` with logrotate:

```bash
/var/log/pmg_backup.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 0640 root root
}
```
