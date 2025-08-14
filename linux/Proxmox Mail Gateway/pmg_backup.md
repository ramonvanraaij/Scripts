# **How to Use the Proxmox Mail Gateway Backup Script**

This guide provides step-by-step instructions to configure and automate the pmg\_backup.sh script for your Proxmox Mail Gateway.

### **1\. Prerequisites**

Before you begin, ensure the necessary tools are installed on your Proxmox Mail Gateway server.

* `mailutils`: Required for sending email notifications.  
* `rsync`: Required if you plan to sync backups to a remote server (`RSYNC_ENABLED="true"`).

You can install them using the following command:
```bash
apt-get update && apt-get install mailutils rsync
```

### **2\. Save the Script**

Save the script content to a file on your PMG server. A common and recommended location is `/usr/local/bin/`.

```bash
# For example, create and edit the file with nano:  
nano /usr/local/bin/pmg_backup.sh

# Paste the script content into the editor and save the file.
```

### **3\. Customize Variables**

Open the script and edit the variables in the **"User-defined Variables"** section to match your environment.

* `MAX_BACKUPS`: Number of local backups to keep.  
* `RSYNC_ENABLED`: Set to `true` or `false`.  
* `REMOTE_HOST`: The IP address or hostname of your remote backup server.  
* `REMOTE_USER`: The username to connect to the remote server.  
* `REMOTE_DIR`: The full path to the directory on the remote server where backups will be stored.  
* `REMOTE_SSH_KEY`: The path to the SSH private key the script should use for passwordless login.  
* `EMAIL_ENABLED`: Set to `true` or `false`.  
* `FROM_ADDRESS` & `RECIPIENT_ADDRESS`: Your desired email notification addresses.

### **4\. Set Up SSH Key Authentication (Crucial for Automation)**

For the script to run automatically without asking for a password, you must set up passwordless SSH login from your PMG server to your backup server.

1. **On your PMG server**, generate an SSH key if you don't already have one:  
```bash
   ssh-keygen -t ed25519  
   # Press Enter to accept the default file location and options.
```

2. **Copy the public key** to your remote backup server. The easiest way is using the ssh-copy-id command. Replace backup and your.server.com with your remote user and host.  
```bash
   ssh-copy-id -i /root/.ssh/id_ed25519.pub backup@your.server.com
```
This command will ask for the remote user's password one last time.

### **5\. Make the Script Executable**

Grant the script execute permissions so that it can be run.
```bash
chmod +x /usr/local/bin/pmg_backup.sh
```

### **6\. Test the Script**

Run the script manually from the command line to ensure everything is working correctly. This allows you to catch any configuration errors or permission issues before automating it.
```bash
/usr/local/bin/pmg_backup.sh
```
Check the console output for any warnings or errors.

### **7\. Schedule with Cron**

Once you've confirmed the script runs successfully, you can schedule it to run automatically using cron.

1. Open the cron table for editing:  
```bash
   crontab -e
```

2. Add a new line to the file to define the schedule. The following example will run the script every day at 2:00 AM:  
```bash
   0 2 * * * /usr/local/bin/pmg_backup.sh
```

3. Save and close the file. The cron job is now active.
