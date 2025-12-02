#!/usr/bin/env python3
# dedupe_roms.py
# =================================================================
# Retro-Gaming ROM Deduplication Tool
#
# Copyright (c) 2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script recursively scans a ROM collection, identifies duplicate
# games across different systems and regions, and organizes them based
# on a strict hierarchy of quality and relevance.
#
# It performs the following actions:
# 1. Scans the 'roms' directory recursively for game files.
# 2. Normalizes filenames to detect duplicates while preserving specific metadata.
# 3. Determines the "best" version using a priority hierarchy:
#    Generation > Release Year > Region > File Size.
# 4. Applies specific rules for Arcade (MAME vs FBNeo) and Handhelds.
# 5. Moves duplicate files to a separate directory for review.
#
# Usage:
#   python3 dedupe_roms.py
#
#   To capture output:
#   python3 dedupe_roms.py > output.log 2>&1
#
# **Note:**
#   The script defaults to DRY_RUN = True. To apply changes, edit the
#   configuration section to set DRY_RUN = False.
# =================================================================

import os
import re
import shutil
from typing import List, Dict, Any, Optional

# --- Configuration ---

# If True, the script will only print what it would do, without moving any files.
DRY_RUN = True

# The directory to scan for ROMs. Defaults to the current directory.
ROMS_PATH = 'roms'

# The directory where duplicate ROMs will be moved.
DUPLICATES_PATH = 'roms/duplicates'

# Log file for handheld exceptions.
LOG_FILE = 'duplicates_log.txt'

# If True, keeps both Handheld and Console versions of the same game (e.g. PSX and GBA).
# If False, they compete against each other based on the generation/year/region rules.
KEEP_HANDHELD_AND_CONSOLE_DUPLICATES = True

# --- Knowledge Base ---

# Generation/release year mapping for various systems to establish hierarchy.
SYSTEM_GENERATIONS: Dict[str, int] = {
    # 3rd Generation (8-bit)
    'nes': 3, 'famicom': 3,
    'mastersystem': 3, 'mark3': 3,
    'sg-1000': 3,
    'atari7800': 3,

    # 4th Generation (16-bit)
    'megadrive': 4, 'genesis': 4,
    'snes': 4, 'sfc': 4, 'superfamicom': 4,
    'pcengine': 4, 'tg16': 4,
    'neogeo': 4,
    'segacd': 4,
    'amigacd32': 4,
    'cdi': 4,

    # 5th Generation (32/64-bit)
    'psx': 5,
    'n64': 5,
    'saturn': 5,
    'dreamcast': 5,  # Often considered 6th gen, but fits better here for cross-platform games vs PS2/GC
    '3do': 5,
    'jaguar': 5,
    'pcfx': 5,
    'sega32x': 5,
    'virtualboy': 5,

    # 6th Generation
    'ps2': 6,
    'gc': 6, 'gamecube': 6,
    'xbox': 6,

    # 7th Generation
    'wii': 7,
    'ps3': 7,
    'xbox360': 7,

    # 8th Generation
    'wiiu': 8,
    'ps4': 8,
    'switch': 8,  # Hybrid generation, placed here for comparison

    # Arcade
    'mame': 4,   # Placed in 16-bit era for general comparison
    'fbneo': 4,  # Placed in 16-bit era for general comparison

    # Pre-NES
    'atari2600': 2,
    'atari5200': 2,
    'intellivision': 2,
    'colecovision': 2,
    'channelf': 1,
    'odyssey2': 1, 'videopac': 1,
    'vectrex': 2,

    # Handhelds (Generations aligned with home consoles)
    'gameboy': 3,
    'gamegear': 4,
    'lynx': 4, 'atarilynx': 4,
    'gbc': 5,
    'ngp': 5, 'ngpc': 5, 'neogeopocketcolor': 5,
    'wonderswan': 5, 'wswan': 5,
    'wonderswancolor': 5, 'wswanc': 5,
    'gba': 6,
    'psp': 7,
    'nds': 7,
    '3ds': 8,
    'psvita': 8,
    'gamepock': 3,
    'supervision': 4,
    'gamate': 4,
    'gamecom': 5,
}

# Systems classified as handhelds for the exception rule (keep both Console and Handheld versions).
HANDHELD_SYSTEMS = {
    'gameboy', 'gb',
    'gamegear',
    'lynx', 'atarilynx',
    'gbc',
    'ngp', 'ngpc', 'neogeopocketcolor',
    'wonderswan', 'wswan',
    'wonderswancolor', 'wswanc',
    'gba',
    'psp',
    'nds',
    '3ds', 'n3ds',
    'psvita',
    'gamepock',
    'supervision',
    'gamate',
    'gamecom',
    'pokemini',
    'vsmile',
}


# --- Core Functions ---

def get_supported_extensions(system_path: str) -> List[str]:
    """
    Parses systeminfo.txt to get a list of supported file extensions for a system.
    
    Args:
        system_path: Path to the system directory.
        
    Returns:
        List of supported extensions (e.g., ['.zip', '.iso']).
    """
    systeminfo_path = os.path.join(system_path, 'systeminfo.txt')
    if os.path.exists(systeminfo_path):
        with open(systeminfo_path, 'r', encoding='utf-8') as f:
            for line in f:
                if "Supported file extensions:" in line:
                    # Read the next line which contains the extensions
                    extensions_line = next(f, '').strip()
                    return [ext.strip().lower() for ext in extensions_line.split()]
    # Default fallback extensions if systeminfo.txt is missing
    return ['.zip', '.7z', '.iso', '.cue', '.chd']


def normalize_game_name(filename: str) -> str:
    """
    Normalizes a game filename by removing details in parentheses/brackets,
    but preserves multi-disc and game mode identifiers to prevent false positives.
    
    Args:
        filename: The filename to normalize.
        
    Returns:
        The normalized game name string.
    """
    name = os.path.splitext(filename)[0]
    
    # Define patterns for info to preserve.
    # Order matters if there's overlap, but these should be distinct.
    preserve_patterns = [
        r'[\(\[]\s*(?:disc|disk|cd)\s*[\w\d]+\s*[\) \]]',  # e.g., (Disc 1), [CD2]
        r'\(.*\sMode\)'                                    # e.g., (Arcade Mode)
    ]
    
    preserved_info = []
    for pattern in preserve_patterns:
        matches = re.findall(pattern, name, re.IGNORECASE)
        if matches:
            preserved_info.extend(matches)
            for match in matches:
                # Use a placeholder to avoid replacing parts of other matches
                name = name.replace(match, '---PRESERVED---')

    # Remove any other info in parentheses or brackets (metadata, region, etc.)
    name = re.sub(r'\[.*?\]', '', name)
    name = re.sub(r'\(.*?\)', '', name)
    
    # Restore preserved info
    if preserved_info:
        name = name.replace('---PRESERVED---', '{}').format(*preserved_info)

    return name.strip()


def get_region_priority(filename: str) -> int:
    """
    Determines the region priority of a game file based on tags in the filename.
    LOWER number indicates HIGHER priority.
    
    Priority:
    1. Europe / World / Multi-Language (En,Fr,De)
    2. USA
    3. No Tag / Default
    4. Japan / Asia / Explicit Non-English
    
    Args:
        filename: The filename to analyze.
        
    Returns:
        Integer priority level (1-4).
    """
    filename_lower = filename.lower()
    if any(tag in filename_lower for tag in ['(europe)', '(en,fr,de)', '(world)']):
        return 1
    if any(tag in filename_lower for tag in ['(usa)', '(us)']):
        return 2
    # Explicit non-English regions are deprioritized (Priority 4)
    if any(tag in filename_lower for tag in ['(japan)', '(jp)', '(asia)', '(ko)', '(ch)']):
        return 4
    # Default/No tag (Standard Arcade sets or unknown) -> Priority 3
    return 3


def find_roms(roms_path: str) -> Dict[str, List[Dict[str, Any]]]:
    """
    Recursively finds all ROM files in the given path and groups them by normalized name.
    
    Args:
        roms_path: The root directory to scan.
        
    Returns:
        Dictionary where keys are normalized game names and values are lists of ROM metadata.
    """
    games = {}
    for root, dirs, files in os.walk(roms_path):
        # Skip symlinked directories to prevent infinite loops and processing mapped mounts.
        dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(root, d))]
        
        # Skip the duplicates directory to prevent re-scanning moved files.
        duplicates_abs = os.path.abspath(DUPLICATES_PATH)
        dirs[:] = [d for d in dirs if os.path.abspath(os.path.join(root, d)) != duplicates_abs]

        system = os.path.basename(root)
        extensions = get_supported_extensions(root)

        for file in files:
            if not any(file.lower().endswith(ext) for ext in extensions):
                continue

            normalized_name = normalize_game_name(file)
            if normalized_name not in games:
                games[normalized_name] = []

            # Extract year if present (e.g., (1999))
            year_match = re.search(r'\((\d{4})\)', file)
            year = int(year_match.group(1)) if year_match else 0

            games[normalized_name].append({
                'path': os.path.join(root, file),
                'system': system,
                'filename': file,
                'year': year,
                'region_priority': get_region_priority(file),
                'size': os.path.getsize(os.path.join(root, file))
            })
    return games


def find_best_rom(rom_list: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    """
    Finds the single best ROM from a list based on generation, year, region, and size.
    
    Args:
        rom_list: List of ROM metadata dictionaries.
        
    Returns:
        The dictionary of the 'winning' ROM, or None if list is empty.
    """
    if not rom_list:
        return None
    
    winner = rom_list[0]
    for i in range(1, len(rom_list)):
        competitor = rom_list[i]
        
        # Rule 1: Generation - Higher generation wins.
        # Exception: If a home console game and a handheld game are present for the same title,
        # they are both kept due to the Handheld Rule, handled in resolve_duplicates.
        winner_gen = SYSTEM_GENERATIONS.get(winner['system'], 0)
        competitor_gen = SYSTEM_GENERATIONS.get(competitor['system'], 0)

        if winner_gen != competitor_gen:
            if competitor_gen > winner_gen:
                winner = competitor
        # Rule 2: Release Year (from filename) - Newer year wins if generations are equal.
        else:
            if competitor['year'] > winner['year']:
                winner = competitor
            elif competitor['year'] == winner['year']:
                # Rule 3: Region Priority - Lower number (higher priority) wins if years are also equal.
                if competitor['region_priority'] < winner['region_priority']:
                    winner = competitor
                # Rule 4: File Size (Tie-breaker) - Smaller file size wins if all prior criteria are equal.
                elif competitor['region_priority'] == winner['region_priority']:
                    if competitor['size'] < winner['size']:
                        winner = competitor
            
    return winner


def resolve_duplicates(games: Dict[str, List[Dict[str, Any]]], log_file) -> None:
    """
    Resolves duplicates based on the hierarchy of rules.
    
    Args:
        games: Dictionary of normalized names to ROM lists.
        log_file: File handle for logging exceptions.
    """
    for game_name, roms in games.items():
        if len(roms) <= 1:
            continue

        # Display found duplicates for the current game_name.
        print(f"Found {len(roms)} potential duplicates for '{game_name}':")
        for r in roms:
            print(f"  - {r['path']}")

        candidates = list(roms)

        # --- Special MAME vs FBNeo Rule ---
        # This rule prioritizes FBNeo versions over MAME, unless the FBNeo version is
        # explicitly non-English (region priority 4) AND the MAME version is
        # English/World (region priority 1, 2, or 3).
        mame_rom = next((r for r in candidates if r['system'] == 'mame'), None)
        fbneo_rom = next((r for r in candidates if r['system'] == 'fbneo'), None)

        if mame_rom and fbneo_rom:
            # Region Priority: 1=EU/World, 2=USA, 3=NoTag, 4=Japan/Non-English
            # FBNeo is kept by default unless MAME is clearly a better regional version.
            if fbneo_rom['region_priority'] == 4 and mame_rom['region_priority'] < 4:
                winner = mame_rom
                loser = fbneo_rom
                print(f"  MAME/FBNeo Rule: Keeping MAME (FBNeo is explicitly non-English, MAME is English/World).")
            else:
                winner = fbneo_rom
                loser = mame_rom
                print(f"  MAME/FBNeo Rule: Keeping FBNEO over MAME (FBNeo is generally preferred).")
            
            print(f"    Winner: {winner['path']}")
            print(f"    Moving: {loser['path']}")
            move_duplicate(loser['path'])
            candidates.remove(loser)
        
        # If after the MAME/FBNeo rule, there's only one or zero candidates left, move on.
        if len(candidates) <= 1:
            continue
            
        # --- Handheld Exception & Main Resolution ---
        # If a game exists for both handheld and home console systems, both the best handheld
        # and best console versions are kept IF the configuration allows it.
        # Otherwise, only the single best ROM is kept.
        handhelds = [r for r in candidates if r['system'] in HANDHELD_SYSTEMS]
        consoles = [r for r in candidates if r['system'] not in HANDHELD_SYSTEMS]
        
        kept_roms = [] # List to store the ROM(s) that will be preserved.

        # Case 1: Mixed handheld and console versions AND we want to keep both.
        if handhelds and consoles and KEEP_HANDHELD_AND_CONSOLE_DUPLICATES:
            log_file.write(
                f"Handheld Exception for '{game_name}': Evaluating console and handheld versions separately.\n"
            )
            print(f"  Handheld Exception for '{game_name}': Evaluating console and handheld versions separately.")
            
            # Find the best ROM within the handheld group.
            best_handheld = find_best_rom(handhelds)
            if best_handheld:
                kept_roms.append(best_handheld)
            
            # Find the best ROM within the console group.
            best_console = find_best_rom(consoles)
            if best_console:
                kept_roms.append(best_console)
        
        # Case 2: Only handhelds or only consoles OR we treat them as the same pool.
        else:
            # Find the single best ROM from the remaining candidates.
            best_rom = find_best_rom(candidates)
            if best_rom:
                kept_roms.append(best_rom)
        
        # Move any candidate that was not explicitly selected to be kept.
        for cand in candidates:
            if cand not in kept_roms:
                # Log the winner(s) for context when moving a duplicate.
                winner_paths = [k['path'] for k in kept_roms]
                print(f"  General Rule: Moving '{cand['path']}' (Winner(s): {winner_paths})")
                move_duplicate(cand['path'])


def move_duplicate(file_path: str) -> None:
    """
    Moves a file to the duplicates directory, preserving its relative path structure.
    
    Args:
        file_path: The absolute or relative path of the file to move.
    """
    if not DRY_RUN:
        relative_path = os.path.relpath(file_path, ROMS_PATH)
        dest_path = os.path.join(DUPLICATES_PATH, relative_path)
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        shutil.move(file_path, dest_path)
        print(f"Moved '{file_path}' to '{dest_path}'")
    else:
        print(f"[DRY RUN] Would move '{file_path}'")


def main() -> None:
    """
    Main function to run the script.
    """
    if not os.path.isdir(ROMS_PATH):
        print(f"Error: ROMs directory not found at '{ROMS_PATH}'")
        return
    
    # Only create the duplicates directory if we are actually potentially moving files
    if not DRY_RUN and not os.path.exists(DUPLICATES_PATH):
        os.makedirs(DUPLICATES_PATH)

    print(f"Scanning for ROMs in '{ROMS_PATH}'...")
    games = find_roms(ROMS_PATH)
    print(f"Found {len(games)} unique games.")

    with open(LOG_FILE, 'w', encoding='utf-8') as log_file:
        resolve_duplicates(games, log_file)

    print("\nScript finished.")
    if DRY_RUN:
        print("Dry run complete. No files were moved.")


if __name__ == '__main__':
    main()