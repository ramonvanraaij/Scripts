#!/usr/bin/env bash
# check_aur_infected.sh
# =================================================================
# Check installed packages against the Arch Linux compromised-package list
#
# Copyright (c) 2026 Rámon van Raaij
# License: BSD-3-Clause
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script fetches the live list of compromised package names published on
# the official Arch Linux HedgeDoc note and reports any that are installed on
# the local system. It is read-only: it only queries pacman and the public
# list and never modifies the system.
#
# This is a portable shell port of the original fish version: it has no fish
# dependency and runs under bash (and, unchanged, under any POSIX shell such as
# /bin/sh, dash, or the BusyBox ash used by Alpine).
#
# It performs the following actions:
# 1. Fetches the live package-name list from the official Arch Linux HedgeDoc note.
# 2. Verifies the page looks like the expected note (format guard).
# 3. Extracts only the note body (so page chrome cannot leak in), strips HTML,
#    trims whitespace, keeps valid-looking pkgname lines, and de-duplicates.
# 4. Sanity-checks the parsed count to catch a truncated fetch or format change.
# 5. Pass 1 (faithful to the original): intersects the list with FOREIGN packages
#    (pacman -Qmq) -- packages not provided by any sync database (classic AUR builds).
# 6. Pass 2 (broader): intersects the list with ALL installed packages (pacman -Qq),
#    which also catches AUR packages shipped through a binary repo (e.g. Chaotic-AUR
#    on Garuda / CachyOS) -- a blind spot of pass 1.
#
# Usage:
#   ./check_aur_infected.sh        # or: bash check_aur_infected.sh / sh check_aur_infected.sh
#
# Exit codes:
#   0  clean -- no listed package name is installed
#   1  error -- fetch, format, or parse sanity check failed
#   2  one or more listed package names are installed (needs triage)
#
# **Note:**
# - Matches are by package NAME only. A hit means a same-named package is
#   installed, NOT proof of compromise. Triage each hit before acting:
#       pacman -Qi  <pkg>   # build date, packager, "Validated By: Signature"
#       pacman -Qkk <pkg>   # verify files against recorded checksums
#   A signature-validated official package built well before the incident is
#   almost certainly a benign name collision, not the compromised artifact.
# - Requires: curl, pacman, plus sed / grep / sort / comm / mktemp (standard on Arch).
#
# Sources:
# - Original bash script (Kidev):
#     https://gist.github.com/Kidev/85756c3dcad3623ca5604a8135bafd14
# - Fish port (K-4-Z, gist comment):
#     https://gist.github.com/Kidev/85756c3dcad3623ca5604a8135bafd14?permalink_comment_id=6196490
# - Data source, official Arch Linux HedgeDoc note:
#     https://md.archlinux.org/s/SxbqukK6IA
# =================================================================

set -o errexit -o nounset -o pipefail

# --- Configuration ---
LIST_URL="https://md.archlinux.org/s/SxbqukK6IA"
# Truncated-fetch / format-change guard: the real list is hundreds of packages,
# so a parse yielding fewer than this almost certainly means a bad fetch. Tune
# down if the upstream list is ever curated below this size.
MIN_EXPECTED=100
# Marker that identifies the HedgeDoc note body; also where extraction starts.
DOC_MARKER='<div id="doc"'

# Force the C locale so sort, comm and grep all agree on byte ordering. Without
# this, sort uses LC_COLLATE while comm compares byte-wise, and on a UTF-8 host
# the two disagree on punctuation order, which can make comm miss real matches.
export LC_ALL=C

# --- Dependency check ---
# Fail early with a clear message rather than midway through a pipeline.
for cmd in curl pacman sed grep sort comm mktemp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command '$cmd' not found in PATH." >&2
        exit 1
    fi
done

# --- Scratch space ---
# Temp files replace fish's psub process substitution, which keeps the script
# POSIX-safe (BusyBox ash / dash have no <() ). Cleaned up on any exit.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT INT TERM
infected="$tmpdir/infected"
foreign_installed="$tmpdir/foreign_installed"
all_installed="$tmpdir/all_installed"
match_foreign="$tmpdir/match_foreign"
match_all="$tmpdir/match_all"
match_repo_only="$tmpdir/match_repo_only"

# --- Fetch the compromised-package list ---
echo "Fetching infected package list..."

raw=$(curl -fsSL "$LIST_URL") || {
    rc=$?
    echo "ERROR: failed to fetch $LIST_URL (curl exit $rc)" >&2
    exit 1
}

# --- Validate page format ---
# Confirm we actually received the note (not an error page or a body truncated
# before the content starts) before trusting the parse.
if ! printf '%s\n' "$raw" | grep -qF -- "$DOC_MARKER"; then
    echo "ERROR: fetched page does not look like the expected note (missing '$DOC_MARKER')." >&2
    echo "       The note layout may have changed; parse is not trustworthy." >&2
    exit 1
fi

# --- Parse the package list ---
# Extract only the note body (from the doc marker onward) so page chrome
# (header, view counts, usernames, timestamps) cannot leak in as stray tokens;
# strip HTML tags; trim surrounding whitespace (the first list entry is indented
# in the render); keep only sane pkgname lines (lowercase / digits / . _ + -);
# de-duplicate. The note renders as one package name per line.
#
# A malformed page can make grep match nothing (pipeline exit 1); that is not a
# crash condition -- the MIN_EXPECTED guard below reports it cleanly -- so the
# trailing `|| true` stops pipefail from aborting here.
{
    printf '%s\n' "$raw" \
        | sed -n "/$DOC_MARKER/,\$p" \
        | sed 's/<[^>]*>//g; s/^[[:space:]]*//; s/[[:space:]]*$//' \
        | grep -E '^[a-z0-9]([a-z0-9_.+-]*[a-z0-9])?$' \
        | sort -u >"$infected"
} || true

pkg_count=$(wc -l <"$infected" | tr -d '[:space:]')
if [ "$pkg_count" -lt "$MIN_EXPECTED" ]; then
    echo "ERROR: parsed only $pkg_count package(s) (expected >= $MIN_EXPECTED)." >&2
    echo "       The fetch was likely truncated or the note format changed." >&2
    exit 1
fi

echo "Checking $pkg_count known infected packages..."
echo

# --- Collect installed packages ---
# All installed (always non-empty). pacman -Qq is already one name per line.
pacman -Qq | sort >"$all_installed"
# Foreign only (classic AUR builds). On a system with zero foreign packages
# pacman -Qmq can exit non-zero; `|| true` keeps that from aborting under set -e.
{ pacman -Qmq || true; } | sort >"$foreign_installed"

# --- Intersect with the infected list ---
# All inputs are C-locale sorted, so comm's byte-wise compare agrees with sort.
# Pass 1: foreign packages only (classic AUR builds).
comm -12 "$foreign_installed" "$infected" >"$match_foreign"
# Pass 2: all installed packages -- also catches AUR packages shipped through a
# binary repo (e.g. Chaotic-AUR on Garuda), which pass 1 misses.
comm -12 "$all_installed" "$infected" >"$match_all"
# Packages caught only by the broader pass (repo-provided AUR packages). Foreign
# matches are a subset of all matches, so the lines unique to match_all are exactly
# the repo-only hits.
comm -13 "$match_foreign" "$match_all" >"$match_repo_only"

total=$(wc -l <"$match_all" | tr -d '[:space:]')
foreign_n=$(wc -l <"$match_foreign" | tr -d '[:space:]')
repo_n=$(wc -l <"$match_repo_only" | tr -d '[:space:]')

# --- Report ---
if [ "$total" -eq 0 ]; then
    echo "Clean: none of the known infected packages are installed."
    exit 0
fi

echo "WARNING: $total infected package name(s) found:"
echo
echo "Foreign / AUR-built (pacman -Qmq):"
if [ "$foreign_n" -eq 0 ]; then
    echo "  (none)"
else
    while IFS= read -r pkg; do
        printf '  - %s\n' "$pkg"
    done <"$match_foreign"
fi
echo
echo "Repo-provided only (e.g. Chaotic-AUR -- missed by the original check):"
if [ "$repo_n" -eq 0 ]; then
    echo "  (none)"
else
    while IFS= read -r pkg; do
        printf '  - %s\n' "$pkg"
    done <"$match_repo_only"
fi
echo
echo "You may be affected. Matches are by NAME only -- triage each before acting:"
echo "  pacman -Qi  <pkg>   # build date, packager, 'Validated By: Signature'"
echo "  pacman -Qkk <pkg>   # verify files against recorded checksums"
exit 2
