#!/usr/bin/env python3
# backup-to-git.py
# =================================================================
# Automated Backup to Git Repository
#
# Copyright (c) 2024-2026 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script uses rsync to back up specified files and directories to a local
# Git repository and pushes the changes to a remote repository.
#
# It performs the following actions:
# 1. Reads a list of source paths from a configuration file.
# 2. Uses rsync to copy these paths to a local Git repository structure.
# 3. Stages all changes in the Git repository.
# 4. Commits changes with a timestamped message if modifications are detected.
# 5. Pushes the commit to the remote Git repository.
#
# Usage:
#   python3 backup-to-git.py
#
# **Note:**
#   - Requires 'rsync' and 'git' installed.
#   - SSH keys must be configured for passwordless Git push.
# =================================================================

import os
import sys
import subprocess
import datetime
from pathlib import Path

# --- Configuration ---
# The destination directory (local Git repository)
BACKUP_DIR = Path("path_to_backupdir/gitbackup/rootfs/")
# File containing the list of files/directories to back up
BACKUP_SOURCE_FILE = Path("path_to_backup.sources_file/backup.sources")
IGNORE_COMMENT = "#"

# --- Core Functions ---

def log_message(message):
    """
    Logs a message with a timestamp to stdout.
    
    Args:
        message (str): The message to log.
    """
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"{timestamp} - {message}")

def run_command(command, cwd=None, check=True):
    """
    Runs a shell command and logs errors.
    
    Args:
        command (list): The command and its arguments.
        cwd (Path, optional): The directory to run the command in.
        check (bool): Whether to raise an error if the command fails.
        
    Returns:
        subprocess.CompletedProcess: The result of the command execution.
    """
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            check=check,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        return result
    except subprocess.CalledProcessError as e:
        log_message(f"ERROR: Command failed: {' '.join(command)}")
        log_message(f"Stderr: {e.stderr.strip()}")
        if check:
            raise e
        return e

def rsync_path(source, destination_root):
    """
    Rsyncs a source path to the destination directory, preserving structure.
    Removes the root '/' from source to create a relative path inside destination.
    
    Args:
        source (str): Path to the source file or directory.
        destination_root (Path): The base path for the backup.
    """
    source_path = Path(source)
    
    # Calculate the relative path structure to preserve
    # e.g. /etc/nginx/nginx.conf -> etc/nginx/
    if source_path.is_absolute():
        relative_path = source_path.relative_to(source_path.anchor)
    else:
        relative_path = source_path

    # The destination directory for this specific file/folder
    dest_path = destination_root / relative_path.parent
    
    if not dest_path.exists():
        try:
            dest_path.mkdir(parents=True, exist_ok=True)
        except OSError as e:
            log_message(f"Error creating directory {dest_path}: {e}")
            return

    # Rsync options: -a (archive), -v (verbose), -z (compress), --delete (delete extraneous)
    cmd = ["rsync", "-avz", "--delete", str(source_path), str(dest_path)]
    
    try:
        run_command(cmd)
    except subprocess.CalledProcessError:
        log_message(f"Failed to rsync {source_path}")

def git_operations(repo_dir):
    """
    Stages, commits, and pushes changes in the git repository.
    
    Args:
        repo_dir (Path): The path to the local Git repository.
    """
    git_dir = repo_dir / ".git"
    if not git_dir.exists():
        log_message(f"Error: {repo_dir} is not a git repository.")
        return

    log_message("Staging changes...")
    try:
        run_command(["git", "add", "."], cwd=repo_dir)
    except subprocess.CalledProcessError:
        log_message("Failed to add files to git.")
        return

    # Check for changes
    try:
        status_result = run_command(["git", "status", "--porcelain"], cwd=repo_dir)
        if not status_result.stdout.strip():
            log_message("No changes to commit.")
            return
    except subprocess.CalledProcessError:
        log_message("Failed to check git status.")
        return

    log_message("Changes detected. Committing...")
    date_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    commit_msg = f"Automatic backup on {date_str}"
    
    try:
        run_command(["git", "commit", "-m", commit_msg], cwd=repo_dir)
        log_message("Pushing to remote...")
        run_command(["git", "push"], cwd=repo_dir)
        log_message("Backup pushed successfully.")
    except subprocess.CalledProcessError:
        log_message("Git commit or push failed.")

# --- Main Execution ---

def main():
    log_message("Starting backup-to-git process...")

    if not BACKUP_SOURCE_FILE.exists():
        log_message(f"FATAL: Source file {BACKUP_SOURCE_FILE} not found.")
        sys.exit(1)

    if not BACKUP_DIR.exists():
        log_message(f"Creating backup directory: {BACKUP_DIR}")
        try:
            BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        except OSError as e:
            log_message(f"FATAL: Could not create backup dir: {e}")
            sys.exit(1)

    # Process backup sources
    with open(BACKUP_SOURCE_FILE, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith(IGNORE_COMMENT):
                continue
            
            # Expand ~ to user home if present
            source_path = os.path.expanduser(line)
            
            log_message(f"Processing: {source_path}")
            rsync_path(source_path, BACKUP_DIR)

    # Git commit and push
    git_operations(BACKUP_DIR)
    
    log_message("Backup process completed.")

if __name__ == "__main__":
    main()