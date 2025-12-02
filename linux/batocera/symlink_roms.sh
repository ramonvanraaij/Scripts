#!/usr/bin/env bash
# symlink_roms.sh
# =================================================================
# Batocera/RetroDeck ROM Folder Smart Symlink Migration Script
#
# Copyright (c) 2024-2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script automates the migration and organization of ROM folders for Batocera and RetroDeck
# environments by creating smart symlinks between common alternative system folder names.
# It helps consolidate ROM collections and ensure consistency across different frontends.
#
# It performs the following actions:
# 1. Identifies pairs of system ROM folders (e.g., 'genesis' and 'megadrive').
# 2. Defines what constitutes an "Empty" folder (containing no ROMs, only metadata files like systeminfo.txt or _info.txt).
# 3. Preserves `_info.txt` files by moving them to the designated "Master" folder before deleting an "Empty" folder.
# 4. If one folder contains games (Master) and the other is Empty, it creates a symlink from the Empty folder to the Master.
# 5. Reports conflicts if both folders in a pair contain games, requiring manual resolution.
#
# Usage:
#   Run this script from the root of your Batocera/RetroDeck ROMs directory (e.g., /userdata/roms).
#   Example: /userdata/roms/symlink_roms.sh
#
# **Note:**
#   Review the `EXECUTE MAPPINGS` section to understand which folders are paired.
#   Conflicts are logged to `migration_conflicts.txt` in the ROM_PATH.
# =================================================================

# Path to the root of the ROMs directory, typically /userdata/roms on Batocera/RetroDeck.
ROM_PATH="/userdata/roms"
# Log file to record conflicts that require manual intervention.
LOG_FILE="$ROM_PATH/migration_conflicts.txt"

# Clear log from previous runs.
echo "Smart Migration Log - $(date)" > "$LOG_FILE"

echo "Starting Smart Migration ..."
echo "Root Path: $ROM_PATH"
echo "------------------------------------------------"

cd "$ROM_PATH" || { echo "Directory not found!"; exit 1; }

# --- Helper Function: has_real_data ---
# Purpose: Checks if a given folder contains "real" data (games/subfolders)
#          or if it's considered "empty" (only containing systeminfo.txt, _info.txt, or nothing).
# Arguments:
#   $1: FOLDER - The path to the directory to check.
# Returns:
#   0 (True): If the folder contains actual game files or subdirectories (real data).
#   1 (False): If the folder is empty, missing, or only contains metadata files.
has_real_data() {
    FOLDER="$1"
    
    # Check if the folder exists as a directory.
    if [ ! -d "$FOLDER" ]; then
        return 1 # Folder does not exist, thus considered empty of real data.
    fi

    # Use find to search for any content that is NOT a dot (.), systeminfo.txt, or _info.txt
    # -maxdepth 1 ensures only direct contents of the folder are checked.
    # We specifically look for *any* file or subdirectory that is not on the ignore list.
    HAS_CONTENT=$(find "$FOLDER" -maxdepth 1 -not -name "." -not -name "systeminfo.txt" -not -name "_info.txt" | head -n 1)

    if [ -n "$HAS_CONTENT" ]; then
        return 0 # Found content other than ignored metadata, so it has real data.
    else
        return 1 # Only ignored metadata or truly empty.
    fi
}

# --- Helper Function: preserve_info_txt ---
# Purpose: Moves the _info.txt file from a source folder to a destination folder
#          if the source has it and the destination doesn't.
# Arguments:
#   $1: SRC - The source folder (which might be deleted).
#   $2: DEST - The destination folder (the master).
preserve_info_txt() {
    SRC="$1"
    DEST="$2"

    # Check if the source folder contains an _info.txt file.
    if [ -f "$SRC/_info.txt" ]; then
        # Check if the destination folder is MISSING the _info.txt file.
        if [ ! -f "$DEST/_info.txt" ]; then
            echo "      [INFO] Moving _info.txt from '$SRC' to '$DEST/'"
            mv "$SRC/_info.txt" "$DEST/" # Move the file to preserve its content.
        else
             echo "      [INFO] _info.txt already exists in '$DEST'. Ignoring move from '$SRC'."
        fi
    fi
}

# --- Main Logic Function: smart_link ---
# Purpose: Compares two related ROM folders (e.g., "genesis" and "megadrive")
#          and creates a symlink from the "empty" folder to the "master" folder,
#          or logs a conflict if both contain games.
# Arguments:
#   $1: NAME_A - The primary/preferred folder name (e.g., "genesis").
#   $2: NAME_B - The secondary/alternative folder name (e.g., "megadrive").
smart_link() {
    NAME_A="$1"  # Represents the primary/preferred folder name (e.g., RetroDeck standard).
    NAME_B="$2"  # Represents the secondary/alternative folder name (e.g., Batocera standard).

    echo "Checking pair: [$NAME_A] vs [$NAME_B]..."

    # Determine the status (DATA or EMPTY) for both folders using the helper function.
    if has_real_data "$NAME_A"; then STATUS_A="DATA"; else STATUS_A="EMPTY"; fi
    if has_real_data "$NAME_B"; then STATUS_B="DATA"; else STATUS_B="EMPTY"; fi

    # --- LOGIC FLOW FOR FOLDER PAIRS ---

    # CASE 1: Both folders contain real games.
    # This is a conflict that requires manual resolution, as the script cannot
    # intelligently merge the contents. The pair is skipped and logged.
    if [ "$STATUS_A" == "DATA" ] && [ "$STATUS_B" == "DATA" ]; then
        echo "  [!!] CONFLICT: Both folders '$NAME_A' and '$NAME_B' contain games."
        echo "       Action: Skipped. Please merge manually to avoid data loss."
        echo "Conflict: '$NAME_A' and '$NAME_B' both have games." >> "$LOG_FILE"

    # CASE 2: The primary folder (NAME_A) has data, and the secondary (NAME_B) is empty.
    # In this scenario, NAME_A is considered the master. NAME_B is cleaned up (its _info.txt preserved)
    # and then replaced with a symlink pointing to NAME_A.
    elif [ "$STATUS_A" == "DATA" ] && [ "$STATUS_B" == "EMPTY" ]; then
        # Ensure NAME_B exists as a directory and is not already a symlink.
        if [ -d "$NAME_B" ] && [ ! -L "$NAME_B" ]; then
            echo "  [FIX] '$NAME_A' is Master. Cleaning up '$NAME_B'..."
            preserve_info_txt "$NAME_B" "$NAME_A" # Preserve _info.txt from NAME_B if applicable.
            rm -rf "$NAME_B"                    # Remove the now empty (or metadata-only) folder.
            ln -s "$NAME_A" "$NAME_B"           # Create a symlink from NAME_B to NAME_A.
            echo "        Linked '$NAME_B' -> '$NAME_A'"
        fi

    # CASE 3: The secondary folder (NAME_B) has data, and the primary (NAME_A) is empty.
    # Similar to CASE 2, but NAME_B is now the master. NAME_A is cleaned up and symlinked to NAME_B.
    elif [ "$STATUS_A" == "EMPTY" ] && [ "$STATUS_B" == "DATA" ]; then
        # Ensure NAME_A exists as a directory and is not already a symlink.
        if [ -d "$NAME_A" ] && [ ! -L "$NAME_A" ]; then
            echo "  [FIX] '$NAME_B' is Master. Cleaning up '$NAME_A'..."
            preserve_info_txt "$NAME_A" "$NAME_B" # Preserve _info.txt from NAME_A if applicable.
            rm -rf "$NAME_A"                    # Remove the now empty (or metadata-only) folder.
            ln -s "$NAME_B" "$NAME_A"           # Create a symlink from NAME_A to NAME_B.
            echo "        Linked '$NAME_A' -> '$NAME_B'"
        fi

    # CASE 4: Both folders are empty (or only contain metadata files).
    # If both are empty, the script defaults to using NAME_A as the canonical folder.
    # NAME_B is cleaned up (its _info.txt preserved), removed, and then symlinked to NAME_A.
    elif [ "$STATUS_A" == "EMPTY" ] && [ "$STATUS_B" == "EMPTY" ]; then
        # Only proceed if NAME_B actually exists as a directory and is not a symlink.
        if [ -d "$NAME_B" ] && [ ! -L "$NAME_B" ]; then
            echo "  [DEFAULT] Both '$NAME_A' and '$NAME_B' are empty. Defaulting to '$NAME_A' as master."
            mkdir -p "$NAME_A"                  # Ensure the master folder exists.
            preserve_info_txt "$NAME_B" "$NAME_A" # Preserve _info.txt from NAME_B if applicable.
            rm -rf "$NAME_B"                    # Remove the empty/metadata-only folder.
            ln -s "$NAME_A" "$NAME_B"           # Create a symlink from NAME_B to NAME_A.
            echo "        Linked '$NAME_B' -> '$NAME_A'"
        fi
    fi
}

# ==============================================================================
# EXECUTE MAPPINGS
# smart_link "RetroDeck_Name" "Batocera_Name"
# ==============================================================================

# --- Sega ---
smart_link "genesis" "megadrive"
smart_link "segacd" "megacd"       # Note: We prefer segacd for Batocera if both contain data, adjust order if you prefer megacd
smart_link "mark3" "mastersystem"
smart_link "sg-1000" "sg1000"

# --- Nintendo ---
smart_link "famicom" "nes"
smart_link "sfc" "snes"
smart_link "gc" "gamecube"
smart_link "n3ds" "3ds"

# --- NEC ---
smart_link "tg16" "pcengine"
smart_link "tg-cd" "pcenginecd"

# --- Atari ---
smart_link "atarilynx" "lynx"
smart_link "atarijaguar" "jaguar"
smart_link "atarixe" "atari800"

# --- Handhelds ---
smart_link "wonderswan" "wswan"
smart_link "wonderswancolor" "wswanc"

# --- Computers ---
smart_link "amiga" "amiga500"
smart_link "bbcmicro" "bbc"
smart_link "cdimono1" "cdi"
smart_link "vic20" "c20"
smart_link "plus4" "cplus4"
smart_link "to8" "thomson"
smart_link "videopac" "odyssey2"

# --- MSX ---
smart_link "msx" "msx2"

echo "------------------------------------------------"
echo "Smart Migration Complete."
echo "Any conflicts were logged to: $LOG_FILE"
