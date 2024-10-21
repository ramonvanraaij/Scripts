#!/usr/bin/python3

"""
Copyright (c) 2024 Rámon van Raaij

License: MIT

Author: Rámon van Raaij | X: @ramonvanraaij | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu

backup.py - This Python 3 script uses rsync to back up files and directories.

It reads a list of files and directories from a source file (`backupsource`) and copies them to a destination directory (`backupdir`).

**Note:**

* This script requires the `rsync` utility.
* The destination directory (`backupdir`) should be a local Git repository.
* An external Git repository with a user account and SSH public key is needed to push the local repository.
"""

import os
import subprocess
import datetime

# Define variables
backupdir = "/root/backups/server-root/"
ignore_comment = "#"  # Lines starting with this character will be ignored
backupsource = "/root/scripts/backup.sources"  # Replace with your actual source file name

def remove_last_dir(path):
    """Removes the last directory component from a given path."""
    if not path:
        return ""  # Handle empty paths

    for _ in range(1):  # Loop only once
        path = path.rsplit("/", 1)[0]
    return path.lstrip("/")


def rsync_recursive(source, destination):
    # Recursively copies files/directories using rsync.
    rsync_cmd = ["rsync", "-avz", "--delete", source, destination]
    subprocess.run(rsync_cmd, check=True)


# Read lines from the backup source file
with open(backupsource, "r") as f:
    for line in f:
        # Skip lines that start with a comment character
        if line.startswith(ignore_comment):
            continue

        input_path = line.strip()
        output_dir = remove_last_dir(input_path)
        backup_path = os.path.join(backupdir, output_dir)

        # Check if the directory already exists
        if not os.path.exists(backup_path):
            # Create the backup directory if it doesn't exist
            os.makedirs(backup_path, exist_ok=True)

        # Use rsync to copy the file/directory recursively
        rsync_recursive(input_path, backup_path)

# Commit changes to Git:
os.chdir(backupdir)
process = subprocess.Popen(["git", "add", "."], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
stdout, stderr = process.communicate()

# Check if there are errors from git add
if process.returncode != 0:
    print(f"Error adding files to Git: {stderr.decode()}")
    exit(1)  # Exit the script with an error

# Check for changes using git diff or git status
has_changes = False
diff_output = subprocess.run(["git", "diff", "--cached"], capture_output=True, text=True).stdout
if diff_output.strip():  # Check if diff output is not empty
    has_changes = True
else:
    status_output = subprocess.run(["git", "status"], capture_output=True, text=True).stdout
    if "nothing to commit, working tree clean" not in status_output:
        has_changes = True

# Proceed with commit only if there are changes
if has_changes:
    date = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    try:
        subprocess.run(["git", "commit", "-m", f"Automatic backup on {date}"], check=True)
        subprocess.run(["git", "push"], check=True)  # Push changes to the remote repository
    except subprocess.CalledProcessError as e:
        print(f"Error committing and pushing changes: {e}")
else:
    print("No changes to commit. Skipping git commit and push.")

