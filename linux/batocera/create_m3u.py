#!/usr/bin/env python3
# create_m3u.py
# =================================================================
# A Python script to generate .m3u playlists for multi-disc ROMs
#
# Copyright (c) 2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script scans a specified ROMs directory for multi-disc games (e.g.,
# "Game (Disc 1).chd", "Game (Disc 2).chd") and generates .m3u playlist files
# for them. These .m3u files allow frontends like Batocera or RetroDeck
# to properly handle multi-disc games as a single entry.
#
# It performs the following actions:
# 1. Recursively scans the 'roms' directory, ignoring common media folders.
# 2. Identifies ROMs based on specified valid extensions.
# 3. Extracts a clean game name by stripping disc-specific tags (e.g., "(Disc 1)").
# 4. Groups ROMs belonging to the same game and generates a .m3u playlist if
#    more than one disc is found for that game.
# 5. Sorts the discs within the playlist naturally (e.g., Disc 1, Disc 2, ..., Disc 10).
#
# Usage:
#   Run this script from the directory containing your 'roms' folder.
#   python3 create_m3u.py
#
#   Ensure ROM files are named consistently with disc indicators (e.g., "(Disc 1)").
#
# **Note:**
#   - Only creates playlists for games with 2 or more discs by default.
#     To include single-disc "playlists", remove the `if len(discs) < 2:` check.
#   - The script will not move or delete any files. It only creates .m3u files.
# =================================================================
import os
import re
import sys

# --- Configuration ---
ROMS_DIR = "/userdata/roms"
VALID_EXTENSIONS = {".chd", ".cue", ".gdi", ".iso", ".cdi", ".bin", ".img", ".nrg", ".udf", ".mdf", ".mds", ".pbp", ".cso", ".ciso", ".gcm", ".gcz", ".wbfs", ".rvz", ".elf", ".dol", ".CHD", ".CUE", ".GDI", ".ISO", ".CDI", ".BIN", ".IMG", ".NRG", ".UDF", ".MDF", ".MDS", ".PBP", ".CSO", ".CISO", ".GCM", ".GCZ", ".WBFS", ".RVZ", ".ELF", ".DOL"}
IGNORE_FOLDERS = {"images", "manuals", "videos", "media", "boxart", "wheels", "trailers", "titles", "snaps"}

# --- Regex Patterns ---
# Regex to identify and strip disc tags
# Matches: (Disc 1), [Disc 1], (CD 1), (Disk 1 of 2), etc.
DISC_PATTERN = re.compile(r'(?i)\s*([(\[])(disc|disk|cd)\s*\d+(\s*of\s*\d+)?([)\]])')
# Regex to clean up empty brackets left behind: () or []
EMPTY_BRACKETS_PATTERN = re.compile(r'\s*([(\[]\s*[)\]])')

# --- Helper Functions ---
def natural_sort_key(s):
    """
    Sorts strings containing numbers naturally (Disc 1, Disc 2, Disc 10).
    Instead of ASCII sort (Disc 1, Disc 10, Disc 2).
    """
    return [int(text) if text.isdigit() else text.lower()
            for text in re.split(r'(\d+)', s)]

# --- Main Logic ---
def main():
    """
    Main function to orchestrate the ROM scanning and .m3u playlist generation.
    """
    if not os.path.exists(ROMS_DIR):
        print(f"Error: Directory '{ROMS_DIR}' not found.")
        sys.exit(1)

    print("--- Starting Python .m3u Generator ---")
    
    # Dictionary to store playlists: 
    # Key = "path/to/Game Name.m3u"
    # Value = ["Game (Disc 1).chd", "Game (Disc 2).chd"]
    playlists = {}

    # Walk through the directory tree
    for root, dirs, files in os.walk(ROMS_DIR):
        # Modify dirs in-place to skip media folders to prevent recursion into them
        # (This is more efficient than checking every file)
        dirs[:] = [d for d in dirs if d.lower() not in IGNORE_FOLDERS]

        for filename in files:
            # 1. Check Extension
            ext = os.path.splitext(filename)[1].lower()
            if ext not in VALID_EXTENSIONS:
                continue

            # 2. Check for "Disc/CD" in the name
            # If it doesn't have "Disc" or "CD", we ignore it
            if not re.search(r'(?i)(disc|disk|cd)', filename):
                continue

            # 3. Create the clean Game Name
            # Remove the (Disc X) part
            clean_name = DISC_PATTERN.sub('', os.path.splitext(filename)[0])
            # Remove empty brackets () or []
            clean_name = EMPTY_BRACKETS_PATTERN.sub('', clean_name)
            # Normalize whitespace (remove double spaces, trim ends)
            clean_name = " ".join(clean_name.split())

            # Skip if name became empty
            if not clean_name:
                print(f"Skipping ambiguous file: {filename}")
                continue

            # 4. Determine Playlist Path
            m3u_filename = f"{clean_name}.m3u"
            m3u_path = os.path.join(root, m3u_filename)

            # Add to dictionary
            if m3u_path not in playlists:
                playlists[m3u_path] = []
            
            playlists[m3u_path].append(filename)

    # Process and Write Playlists
    count = 0
    if not playlists:
        print("No multi-disc games found.")
        return

    for m3u_path, discs in playlists.items():
        # Sort the discs naturally
        discs.sort(key=natural_sort_key)

        # Optional: Only create m3u if there is more than 1 disc?
        # Remove this if-block if you WANT playlists for single files named "Disc 1"
        if len(discs) < 2:
            # print(f"Skipping single-disc match: {discs[0]}")
            continue

        # Content to write
        playlist_content = "\n".join(discs)

        # Check if file exists and content is identical
        if os.path.exists(m3u_path):
            try:
                with open(m3u_path, 'r', encoding='utf-8') as f:
                    existing_content = f.read()
                if existing_content == playlist_content:
                    print(f"☑️ Skipped existing: {m3u_path} ({len(discs)} discs) - content identical")
                    continue
            except Exception:
                # Ignore read errors, just overwrite if we can't verify
                pass

        # Write to file
        try:
            with open(m3u_path, 'w', encoding='utf-8') as f:
                f.write(playlist_content)
            print(f"✅ Created: {m3u_path} ({len(discs)} discs)")
            count += 1
        except Exception as e:
            print(f"❌ Error writing {m3u_path}: {e}")

    print(f"--- Complete. Generated {count} playlists. ---")

if __name__ == "__main__":
    main()

