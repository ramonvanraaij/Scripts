#!/opt/bin/bash
# qnap_realtime_sync.sh
# =================================================================
# QNAP Real-Time Sync to TrueNAS
#
# Copyright (c) 2026 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script monitors specific directories on the QNAP NAS for changes
# using inotifywait and instantly synchronizes them to a TrueNAS Rsync
# server. It includes a debouncing mechanism to batch rapid changes
# and an SMTP alerting system for failures.
#
# It performs the following actions:
# 1. On startup (daemon mode), runs an immediate rsync to catch changes
#    missed while offline.
# 2. Watches only the explicitly configured SYNC_DIRS (not the entire
#    volume) for filesystem events using inotifywait.
# 3. When a change is detected, starts a debounce timer. Further events
#    during the timer window are absorbed. Once the timer expires, rsync
#    runs and the cycle resets.
# 4. Sends an SMTP email alert if any rsync job fails.
#
# Usage:
#   /opt/etc/qnap_realtime_sync.sh --daemon     (Run as background daemon)
#   /opt/etc/qnap_realtime_sync.sh --initial    (Run in foreground with progress)
#   /opt/etc/qnap_realtime_sync.sh --stop       (Stop the running daemon)
#   /opt/etc/qnap_realtime_sync.sh --status [N] (Show status; optionally refresh every N seconds)
#   /opt/etc/qnap_realtime_sync.sh --test-email (Send a test email to verify SMTP config)
#   /opt/etc/qnap_realtime_sync.sh --help       (Show usage information)
#
# Prerequisites:
#
# QNAP:
#   - Entware installed with the following packages:
#       opkg install bash inotify-tools rsync msmtp
#   - Rsync password file at /opt/etc/rsync_truenas.secret (chmod 600)
#     containing the plaintext password for the TrueNAS rsync user.
#   - Auto-start entry in Entware.sh:
#       /opt/etc/qnap_realtime_sync.sh --daemon
#
# TrueNAS:
#   - Rsync module configured (e.g., "backups") with:
#       - Rsync daemon listening on the configured port (default: 30873)
#       - Rsync user matching the DEST_RSYNC and PASSWORD_FILE credentials
#       - Destination dataset with write permissions for the rsync user
#
# **Note:**
# inotifywait must NOT monitor the entire /share/CACHEDEV1_DATA volume.
# QNAP system directories (.qpkg/, .samba/, etc.) generate constant
# filesystem events (~9/sec) that would starve the debounce timer,
# preventing rsync from ever firing. Instead, we pass only the
# SYNC_DIRS paths to inotifywait.
# =================================================================

set -o pipefail

# --- Configuration ---

# Root of the QNAP data volume containing all shared folders
SOURCE_DIR="/share/CACHEDEV1_DATA"

# TrueNAS rsync daemon target - format: rsync://USER@HOST:PORT/MODULE
DEST_RSYNC="rsync://rsync@YOUR_TRUENAS_IP:30873/backups"

# File containing the rsync password (chmod 600). Prevents rsync from
# prompting interactively, which would hang the daemon.
PASSWORD_FILE="/opt/etc/rsync_truenas.secret"

# All daemon activity is appended here for troubleshooting
LOG_FILE="/var/log/qnap_realtime_sync.log"

# PID file - written on daemon start, used by --stop to find and kill the process.
PID_FILE="/var/run/qnap_sync.pid"

# Stats file - accumulates transfer statistics across sync runs for --status.
# Reset on each daemon start. Format: key=value, one per line.
STATS_FILE="/tmp/qnap_sync_stats"

# Log rotation settings - the script rotates its own log because QNAP does not
# ship a standard logrotate configuration.
LOG_MAX_SIZE=$((10 * 1024 * 1024))  # 10 MB - rotate when the active log exceeds this
LOG_KEEP=3                           # Number of compressed archives to retain
                                     # Total worst-case disk usage: ~10 MB active +
                                     # 3 x ~1 MB compressed = ~13 MB (well under 1 GB)

# Email Configuration - used by send_alert() on sync failures.
#
# Supported protocols (set via SMTP_SERVER URL scheme):
#   smtp://host:port     - plain SMTP (no encryption)
#   smtps://host:port    - implicit TLS (typically port 465)
#   smtp://host:587      - STARTTLS upgrade (set SMTP_TLS="starttls")
#
# Authentication: set SMTP_USER and SMTP_PASS to enable. Leave both empty
# for unauthenticated relay (current default).
#
# TLS options:
#   SMTP_TLS=""          - no TLS (default, for trusted LAN relays)
#   SMTP_TLS="starttls"  - upgrade plain connection to TLS via STARTTLS
#   SMTP_TLS="implicit"  - full TLS from the start (use smtps:// scheme)
#
# Certificate verification:
#   SMTP_TLS_VERIFY=true  - verify server certificate (recommended for production)
#   SMTP_TLS_VERIFY=false - skip verification (self-signed certs, testing)
SMTP_SERVER="smtp://YOUR_SMTP_SERVER:25"
SMTP_USER=""
SMTP_PASS=""
SMTP_TLS=""
SMTP_TLS_VERIFY=true
EMAIL_FROM="noreply@example.com"
EMAIL_TO="you@example.com"

# Rsync exclusion list - patterns for files/directories that should never
# be synced, even if they live inside a SYNC_DIR. Trailing slashes match
# directories explicitly. I exclude the usual QNAP system clutter here;
# adjust these to match your own setup.
EXCLUDES=(
    "--exclude=@Recycle/"
    "--exclude=.Trash-1000/"
    "--exclude=@DownloadStationTempFiles/"
    "--exclude=.@__thumb/"
    "--exclude=.@upload_cache/"
    "--exclude=.streams/"
    "--exclude=incomplete/"
    "--exclude=admin/.rnd"
    "--exclude=aquota.user"
    "--exclude=Lost+Found/"
)

# Explicit include list - only these top-level directories under SOURCE_DIR
# are synced. Everything else at the root level is excluded by the
# FILTER_ARGS built below. This same list also controls which directories
# inotifywait monitors. Swap these out for your own shared folder names.
SYNC_DIRS=(
    "Backups"
    "Downloads"
    "homes"
    "Multimedia"
    "Photos"
    "Public"
)

# Construct rsync include/exclude filter arguments from SYNC_DIRS.
# --include=/<dir>/***  recursively includes the directory and all contents.
# The final --exclude=/* drops every other top-level entry.
# Order matters: rsync evaluates filter rules top-to-bottom, first match wins.
FILTER_ARGS=()
for dir in "${SYNC_DIRS[@]}"; do
    FILTER_ARGS+=("--include=/${dir}/***")
done
FILTER_ARGS+=("--exclude=/*")

# --- Functions ---

# Helper function to format log output with timestamps
log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

# Rotates the log file when it exceeds LOG_MAX_SIZE.
# Uses a numbered rotation scheme with gzip compression:
#   qnap_realtime_sync.log        - active log (uncompressed)
#   qnap_realtime_sync.log.1.gz   - most recent rotated log
#   qnap_realtime_sync.log.2.gz   - second most recent
#   qnap_realtime_sync.log.3.gz   - oldest (deleted when a new rotation occurs)
# Called before each rsync run to keep disk usage bounded.
rotate_log() {
    # Skip if the log doesn't exist or hasn't reached the size threshold
    [ -f "$LOG_FILE" ] || return 0
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    [ "$size" -ge "$LOG_MAX_SIZE" ] || return 0

    log_message "Rotating log file (size: $((size / 1024 / 1024)) MB)..."

    # Shift existing archives: .2.gz -> .3.gz, .1.gz -> .2.gz
    # The oldest archive (LOG_KEEP) is silently overwritten
    local i=$LOG_KEEP
    while [ "$i" -gt 1 ]; do
        local prev=$((i - 1))
        [ -f "${LOG_FILE}.${prev}.gz" ] && mv -f "${LOG_FILE}.${prev}.gz" "${LOG_FILE}.${i}.gz"
        i=$prev
    done

    # Compress the current log into the .1.gz slot and start fresh
    gzip -c "$LOG_FILE" > "${LOG_FILE}.1.gz"
    : > "$LOG_FILE"

    log_message "Log rotation complete. Kept $LOG_KEEP compressed archives."
}

# Initializes the stats file with zeroed counters. Called on daemon startup.
init_stats() {
    cat << 'STATSEOF' > "$STATS_FILE"
total_syncs=0
total_files=0
total_bytes_sent=0
total_bytes_received=0
total_seconds=0
total_deletes=0
STATSEOF
}

# Updates the stats file after a successful rsync run.
# Parses rsync's stdout output (captured to a temp file) for transfer stats:
#   - File count: lines that are actual file transfers (not dirs, not "deleting", not headers)
#   - Delete count: lines starting with "deleting "
#   - Bytes sent/received: from "sent X bytes  received Y bytes  Z bytes/sec"
#   - Duration: wall-clock time of the rsync run
# Parameters:
#   $1 - path to the temp file containing rsync's stdout output
#   $2 - duration of the rsync run in seconds
update_stats() {
    local rsync_output="$1"
    local duration="$2"

    [ -f "$STATS_FILE" ] || init_stats
    . "$STATS_FILE"

    # Count transferred files from rsync verbose output.
    # Rsync -v outputs one line per transferred file. We exclude:
    #   - blank lines
    #   - "sending incremental file list" header
    #   - "deleting " lines (counted separately)
    #   - lines ending in / (directories)
    #   - the "sent ... bytes" summary line
    #   - "total size is" summary line
    local new_files=0
    local new_deletes=0
    if [ -s "$rsync_output" ]; then
        new_files=$(grep -cvE '^$|^sending incremental|^deleting |/$|^sent [0-9]|^total size is' "$rsync_output" 2>/dev/null || true)
        new_deletes=$(grep -c '^deleting ' "$rsync_output" 2>/dev/null || true)
        # Ensure values are valid integers (grep -c outputs "0" even on failure,
        # but guard against unexpected output)
        [ -z "$new_files" ] && new_files=0
        [ -z "$new_deletes" ] && new_deletes=0
    fi

    # Parse "sent X bytes  received Y bytes  Z bytes/sec" from rsync output.
    # The numbers may contain commas (e.g., "23,124,668"), which we strip.
    local sent_line
    sent_line=$(grep '^sent [0-9]' "$rsync_output" 2>/dev/null | tail -1)
    local new_sent=0
    local new_received=0
    if [ -n "$sent_line" ]; then
        new_sent=$(echo "$sent_line" | sed 's/,//g' | awk '{print $2}')
        new_received=$(echo "$sent_line" | sed 's/,//g' | awk '{print $5}')
    fi

    # Accumulate
    total_syncs=$((total_syncs + 1))
    total_files=$((total_files + new_files))
    total_deletes=$((total_deletes + new_deletes))
    total_bytes_sent=$((total_bytes_sent + new_sent))
    total_bytes_received=$((total_bytes_received + new_received))
    total_seconds=$((total_seconds + duration))

    # Write back
    cat << STATSEOF > "$STATS_FILE"
total_syncs=$total_syncs
total_files=$total_files
total_bytes_sent=$total_bytes_sent
total_bytes_received=$total_bytes_received
total_seconds=$total_seconds
total_deletes=$total_deletes
STATSEOF
}

# Formats a byte count into a human-readable string (B, KB, MB, GB, TB).
format_bytes() {
    local bytes=$1
    if [ "$bytes" -ge 1099511627776 ] 2>/dev/null; then
        echo "$(awk "BEGIN {printf \"%.2f TB\", $bytes/1099511627776}")"
    elif [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        echo "$(awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}")"
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        echo "$(awk "BEGIN {printf \"%.2f MB\", $bytes/1048576}")"
    elif [ "$bytes" -ge 1024 ] 2>/dev/null; then
        echo "$(awk "BEGIN {printf \"%.2f KB\", $bytes/1024}")"
    else
        echo "${bytes} B"
    fi
}

# Sends an SMTP email alert using curl if a sync job fails.
# Supports plain SMTP, STARTTLS, implicit TLS, and optional authentication
# based on the SMTP_* configuration variables above.
send_alert() {
    local subject="QNAP Sync Alert: Job Failed"
    local message="$1"

    log_message "Attempting to send email alert..."

    # Create a temporary email file formatted for SMTP (RFC 5322 headers + body)
    local email_tmp="/tmp/sync_alert_$$.eml"
    cat << EOF > "$email_tmp"
To: $EMAIL_TO
From: $EMAIL_FROM
Subject: $subject

$message
EOF

    # Build the curl command arguments dynamically based on configuration
    local curl_args=(
        --url "$SMTP_SERVER"
        --mail-from "$EMAIL_FROM"
        --mail-rcpt "$EMAIL_TO"
        --upload-file "$email_tmp"
    )

    # Authentication - only added when SMTP_USER is set
    if [ -n "$SMTP_USER" ]; then
        curl_args+=(--user "${SMTP_USER}:${SMTP_PASS}")
    fi

    # TLS configuration
    case "$SMTP_TLS" in
        starttls)
            # Upgrade plain connection to TLS (RFC 3207), typically on port 587
            curl_args+=(--ssl-reqd)
            ;;
        implicit)
            # Full TLS from the start - requires smtps:// URL scheme (port 465)
            # No extra flag needed; curl handles it via the smtps:// scheme
            ;;
        *)
            # No TLS - plain SMTP (suitable for trusted LAN relays)
            ;;
    esac

    # Certificate verification - disable for self-signed certs or testing
    if [ "$SMTP_TLS_VERIFY" = "false" ]; then
        curl_args+=(--insecure)
    fi

    # Execute curl, suppressing standard output but capturing the exit code
    /opt/bin/curl "${curl_args[@]}" >/dev/null 2>&1
    local curl_status=$?

    rm -f "$email_tmp"

    if [ $curl_status -eq 0 ]; then
        log_message "Email alert sent successfully."
    else
        log_message "Failed to send email alert. Curl exit code: $curl_status"
    fi
}

# Records an error timestamp and checks whether the circuit breaker threshold
# has been reached. If ERROR_THRESHOLD errors have occurred within the last
# ERROR_WINDOW seconds, sends a final alert and terminates the daemon.
record_error() {
    local now
    now=$(date +%s)
    echo "$now" >> "$ERROR_LOG"

    # Prune timestamps older than ERROR_WINDOW
    local cutoff=$((now - ERROR_WINDOW))
    local recent_errors=0
    local tmp_file="${ERROR_LOG}.tmp"
    : > "$tmp_file"
    while IFS= read -r ts; do
        if [ "$ts" -ge "$cutoff" ] 2>/dev/null; then
            echo "$ts" >> "$tmp_file"
            recent_errors=$((recent_errors + 1))
        fi
    done < "$ERROR_LOG"
    mv -f "$tmp_file" "$ERROR_LOG"

    if [ "$recent_errors" -ge "$ERROR_THRESHOLD" ]; then
        local msg="CIRCUIT BREAKER TRIPPED: $recent_errors rsync failures in the last $((ERROR_WINDOW / 60)) minutes. Daemon is shutting down to prevent further damage. Manual intervention required."
        log_message "$msg"
        send_alert "$msg"
        # Kill the entire process group (inotifywait + all subshells)
        kill 0
        exit 1
    fi
}

# Executes the rsync synchronization process with automatic retries.
# Parameters:
#   $1 - mode: "initial" for interactive foreground sync (shows progress bar),
#               "daemon" for background sync (output appended to LOG_FILE).
#
# On failure (after all retries exhausted), sends an email alert containing the
# actual files that failed to transfer, extracted from rsync's stderr output.
#
# Rsync flags used:
#   -r  recursive
#   -l  preserve symlinks
#   -p  preserve permissions
#   -t  preserve modification times
#   -g  preserve group
#   -o  preserve owner (requires root or matching UIDs on both sides)
#   -D  preserve device and special files
#   -v  verbose (daemon mode only - logs which files changed)
#   --delete  remove files on the destination that no longer exist on the source
#   --info=progress2  show a single rolling progress line (initial mode only)
run_rsync() {
    local mode="$1"

    # Rotate the log before each sync to prevent unbounded growth.
    # Verbose rsync output can produce thousands of lines per run.
    rotate_log

    log_message "Starting Rsync job ($mode)..."

    # Read the password fresh each time - the file might have been updated
    export RSYNC_PASSWORD=$(cat "$PASSWORD_FILE")

    if [ "$mode" == "initial" ]; then
        # Interactive mode: print a progress bar to the console for the operator.
        # No retries - the user can see the output and re-run manually.
        /opt/bin/rsync -rlptgoD --info=progress2 --delete "${EXCLUDES[@]}" "${FILTER_ARGS[@]}" "$SOURCE_DIR/" "$DEST_RSYNC/"
        local status=$?
        if [ $status -eq 0 ] || [ $status -eq 23 ] || [ $status -eq 24 ]; then
            log_message "Rsync job completed successfully."
        else
            log_message "Rsync job failed with exit code $status."
        fi
        return $status
    fi

    # --- Daemon mode: run with retries and detailed error capture ---

    local attempt=0
    local max_attempts=$((RSYNC_RETRIES + 1))  # first try + retries
    local status=1
    local rsync_stderr="/tmp/qnap_sync_stderr_$$.log"
    local rsync_stdout="/tmp/qnap_sync_stdout_$$.log"

    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))

        if [ $attempt -gt 1 ]; then
            log_message "Retry $((attempt - 1))/$RSYNC_RETRIES - waiting ${RSYNC_RETRY_DELAY}s..."
            sleep "$RSYNC_RETRY_DELAY"
        fi

        # Run rsync with stdout (file list) captured to a temp file for stats
        # parsing, and also appended to the log. Stderr goes to a separate file
        # for error extraction.
        local start_time
        start_time=$(date +%s)

        # Capture rsync output to both the log file and a temp file for stats.
        # Avoid the pipe to tee - PIPESTATUS is unreliable in nested subshells
        # on some bash builds. Instead, write directly to a temp file, then
        # append to the log afterward.
        /opt/bin/rsync -rlptgoDv --delete \
            "${EXCLUDES[@]}" "${FILTER_ARGS[@]}" \
            "$SOURCE_DIR/" "$DEST_RSYNC/" \
            >"$rsync_stdout" 2>"$rsync_stderr"
        status=$?

        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        # Append rsync stdout and stderr to the log
        if [ -s "$rsync_stdout" ]; then
            cat "$rsync_stdout" >> "$LOG_FILE"
        fi
        if [ -s "$rsync_stderr" ]; then
            cat "$rsync_stderr" >> "$LOG_FILE"
        fi

        # Exit code 0  = total success.
        # Exit code 23 = "Partial transfer due to error" - typically transient
        #                temp files vanishing on an active filesystem.
        # Exit code 24 = "Partial transfer due to vanished source files".
        if [ $status -eq 0 ] || [ $status -eq 23 ] || [ $status -eq 24 ]; then
            update_stats "$rsync_stdout" "$duration"
            log_message "Rsync job completed successfully."
            rm -f "$rsync_stderr" "$rsync_stdout"
            return 0
        fi

        log_message "Rsync job failed with exit code $status (attempt $attempt/$max_attempts)."
    done

    # --- All retries exhausted - build a detailed alert ---

    # Extract the specific files/errors from rsync's stderr output.
    # Typical rsync error lines look like:
    #   rsync: [sender] send_files failed to open "...": Permission denied (13)
    #   rsync: [generator] recv_generator: mkdir "..." failed: No space left (28)
    #   @ERROR: max connections (10) reached -- try again later
    local failed_files=""
    if [ -s "$rsync_stderr" ]; then
        # Grab lines containing actual errors (rsync: or @ERROR), deduplicate
        failed_files=$(grep -E '^(rsync:|@ERROR)' "$rsync_stderr" | sort -u)
    fi

    local err_msg="Rsync job failed with exit code $status after $RSYNC_RETRIES retries.

Host: $(hostname)
Mode: $mode
Source: $SOURCE_DIR/
Destination: $DEST_RSYNC/"

    if [ -n "$failed_files" ]; then
        err_msg="${err_msg}

--- Failed files/errors ---
${failed_files}"
    else
        err_msg="${err_msg}

No specific file errors captured. Check $LOG_FILE on the QNAP for details."
    fi

    log_message "Rsync job failed with exit code $status after $RSYNC_RETRIES retries."
    send_alert "$err_msg"
    rm -f "$rsync_stderr" "$rsync_stdout"

    # Record the error for the circuit breaker
    record_error
}

# --- Rsync Retry Configuration ---

# Number of times to retry a failed rsync before giving up and sending an alert.
# Each retry re-runs the full rsync (which is incremental, so only failed/changed
# files are re-transferred). Set to 0 to disable retries.
RSYNC_RETRIES=3

# Seconds to wait between retries - gives transient issues (network blips,
# locked files) time to resolve.
RSYNC_RETRY_DELAY=5

# --- Circuit Breaker Configuration ---

# If the daemon encounters ERROR_THRESHOLD or more rsync failures within
# ERROR_WINDOW seconds, it terminates itself and sends a final alert.
# This prevents a broken configuration from flooding the email relay and
# consuming resources indefinitely.
ERROR_THRESHOLD=10
ERROR_WINDOW=1800  # 30 minutes

# File that stores unix timestamps of recent errors, one per line.
# Used by the circuit breaker to track error frequency.
ERROR_LOG="/tmp/qnap_sync_errors.log"

# --- Debounce Configuration ---

# How long (in seconds) to wait after the first filesystem event before running
# rsync. This window allows rapid bursts of changes (e.g., extracting an archive)
# to be batched into a single rsync invocation.
DEBOUNCE_SECONDS=10

# Flag file for the debounce mechanism. Its presence means a timer subshell is
# already counting down - further events are safely absorbed until it expires.
SYNC_PENDING="/tmp/qnap_sync_pending"

# --- Main Logic ---

# Clean up the PID file and temp files on exit (normal or signal).
# Uses trap to catch SIGTERM/SIGINT so --stop and kill both clean up properly.
# Only cleans up PID file if this process owns it (avoids --status/--stop
# removing a running daemon's PID file).
# Also kills all child processes (inotifywait, pipe subshells, background syncs)
# to prevent orphaned processes from surviving after the daemon exits.
cleanup() {
    if [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ]; then
        # Kill all children of this process to avoid orphaned inotifywait/subshells
        DESCENDANT_PIDS=()
        get_descendants "$$"
        for dpid in "${DESCENDANT_PIDS[@]}"; do
            kill "$dpid" 2>/dev/null
        done
        rm -f "$PID_FILE" "$SYNC_PENDING" "$ERROR_LOG" "$STATS_FILE"
        log_message "Daemon stopped."
    fi
}
trap cleanup EXIT
trap 'exit 0' TERM INT

# --- Flag Handling ---

show_help() {
    cat << 'HELPEOF'
QNAP Real-Time Sync to TrueNAS

Usage: /opt/etc/qnap_realtime_sync.sh [OPTION]

Options:
  --daemon       Start the background sync daemon. Performs a startup sync,
                 then watches SYNC_DIRS for changes and syncs via rsync.
  --initial      Run a one-time foreground sync with a progress bar.
                 Useful for the first sync or manual catch-up.
  --stop         Stop the running daemon gracefully.
  --status [N]   Show daemon status dashboard with transfer stats, last sync,
                 and error tracker. Pass a number N to auto-refresh every N
                 seconds (like watch). Press Ctrl+C to stop refreshing.
  --test-email   Send a test email to verify SMTP configuration.
  --help         Show this help message.

Files:
  /opt/etc/rsync_truenas.secret    Rsync password (chmod 600)
  /var/log/qnap_realtime_sync.log  Daemon log file
  /var/run/qnap_sync.pid           PID file for daemon management

Examples:
  /opt/etc/qnap_realtime_sync.sh --daemon      # Start the daemon
  /opt/etc/qnap_realtime_sync.sh --status      # Check status once
  /opt/etc/qnap_realtime_sync.sh --status 5   # Live dashboard, refresh every 5s
  /opt/etc/qnap_realtime_sync.sh --stop        # Stop it
  /opt/etc/qnap_realtime_sync.sh --test-email  # Verify email alerts work
HELPEOF
    exit 0
}

# Renders the status dashboard once. Called by show_status which handles
# the optional watch/refresh loop.
render_status() {
    # ANSI color codes
    local BOLD='\033[1m'
    local DIM='\033[2m'
    local RESET='\033[0m'
    local GREEN='\033[32m'
    local RED='\033[31m'
    local YELLOW='\033[33m'
    local CYAN='\033[36m'
    local BLUE='\033[34m'
    local MAGENTA='\033[35m'
    local WHITE='\033[37m'
    local BG_GREEN='\033[42m'
    local BG_RED='\033[41m'
    local BG_YELLOW='\033[43m'
    local BLACK='\033[30m'

    echo ""
    echo -e "  ${BOLD}${CYAN}QNAP Real-Time Sync${RESET}  ${DIM}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"
    echo -e "  ${DIM}$(printf '%.0s─' {1..45})${RESET}"
    echo ""

    # Daemon state
    if [ -f "$PID_FILE" ]; then
        local_pid=$(cat "$PID_FILE")
        if kill -0 "$local_pid" 2>/dev/null; then
            local pid_age
            pid_age=$(( $(date +%s) - $(stat -c%Y "$PID_FILE" 2>/dev/null || echo 0) ))
            local days=$((pid_age / 86400))
            local hours=$(( (pid_age % 86400) / 3600 ))
            local mins=$(( (pid_age % 3600) / 60 ))
            echo -e "  ${BOLD}Status${RESET}   ${BLACK}${BG_GREEN} RUNNING ${RESET}  ${DIM}PID ${local_pid}${RESET}"
            echo -e "  ${BOLD}Uptime${RESET}   ${WHITE}${days}d ${hours}h ${mins}m${RESET}"
        else
            echo -e "  ${BOLD}Status${RESET}   ${BLACK}${BG_RED} STOPPED ${RESET}  ${DIM}stale PID ${local_pid}${RESET}"
        fi
    else
        echo -e "  ${BOLD}Status${RESET}   ${BLACK}${BG_RED} STOPPED ${RESET}"
    fi
    echo ""

    # Transfer statistics
    echo -e "  ${BOLD}${BLUE}Transfer Stats${RESET}  ${DIM}(since daemon start)${RESET}"
    echo -e "  ${DIM}$(printf '%.0s─' {1..45})${RESET}"
    if [ -f "$STATS_FILE" ]; then
        . "$STATS_FILE"
        echo -e "  ${GREEN}▲${RESET} Synced      ${WHITE}${BOLD}$total_files${RESET} files  ${DIM}across${RESET} ${WHITE}${BOLD}$total_syncs${RESET} ${DIM}runs${RESET}"
        echo -e "  ${RED}▼${RESET} Deleted     ${WHITE}${BOLD}$total_deletes${RESET} files"
        echo -e "  ${CYAN}↑${RESET} Sent        ${WHITE}${BOLD}$(format_bytes "$total_bytes_sent")${RESET}"
        echo -e "  ${CYAN}↓${RESET} Received    ${WHITE}${BOLD}$(format_bytes "$total_bytes_received")${RESET}"
        if [ "$total_seconds" -gt 0 ]; then
            local avg_speed=$((total_bytes_sent / total_seconds))
            echo -e "  ${MAGENTA}~${RESET} Avg speed   ${WHITE}${BOLD}$(format_bytes "$avg_speed")/s${RESET}"
            # Format total time nicely
            local th=$((total_seconds / 3600))
            local tm=$(( (total_seconds % 3600) / 60 ))
            local ts=$((total_seconds % 60))
            if [ "$th" -gt 0 ]; then
                echo -e "  ${DIM}◷${RESET} Duration    ${WHITE}${th}h ${tm}m ${ts}s${RESET}"
            elif [ "$tm" -gt 0 ]; then
                echo -e "  ${DIM}◷${RESET} Duration    ${WHITE}${tm}m ${ts}s${RESET}"
            else
                echo -e "  ${DIM}◷${RESET} Duration    ${WHITE}${ts}s${RESET}"
            fi
        else
            echo -e "  ${MAGENTA}~${RESET} Avg speed   ${DIM}N/A${RESET}"
        fi
    else
        echo -e "  ${DIM}No stats available yet.${RESET}"
    fi
    echo ""

    # Circuit breaker / error tracker
    echo -e "  ${BOLD}${YELLOW}Error Tracker${RESET}"
    echo -e "  ${DIM}$(printf '%.0s─' {1..45})${RESET}"
    local recent_errors=0
    if [ -f "$ERROR_LOG" ]; then
        local now cutoff
        now=$(date +%s)
        cutoff=$((now - ERROR_WINDOW))
        recent_errors=$(awk -v c="$cutoff" '$1 >= c' "$ERROR_LOG" 2>/dev/null | wc -l)
    fi
    if [ "$recent_errors" -eq 0 ]; then
        echo -e "  ${GREEN}●${RESET} Circuit breaker  ${GREEN}OK${RESET}  ${DIM}0 / $ERROR_THRESHOLD errors (${ERROR_WINDOW}s window)${RESET}"
    elif [ "$recent_errors" -lt "$ERROR_THRESHOLD" ]; then
        echo -e "  ${YELLOW}●${RESET} Circuit breaker  ${YELLOW}$recent_errors / $ERROR_THRESHOLD${RESET}  ${DIM}errors (${ERROR_WINDOW}s window)${RESET}"
    else
        echo -e "  ${RED}●${RESET} Circuit breaker  ${RED}TRIPPED${RESET}  ${RED}$recent_errors / $ERROR_THRESHOLD${RESET}"
    fi
    echo ""

    # Log file
    echo -e "  ${BOLD}${MAGENTA}Log File${RESET}"
    echo -e "  ${DIM}$(printf '%.0s─' {1..45})${RESET}"
    if [ -f "$LOG_FILE" ]; then
        local log_size
        log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        local archives
        archives=$(ls "${LOG_FILE}".*.gz 2>/dev/null | wc -l)
        echo -e "  Active  ${WHITE}$(format_bytes "$log_size")${RESET}  ${DIM}(rotates at $(format_bytes "$LOG_MAX_SIZE"))${RESET}"
        echo -e "  Archives  ${WHITE}$archives${RESET} / ${DIM}$LOG_KEEP${RESET}"
    else
        echo -e "  ${DIM}Log file not found.${RESET}"
    fi
    echo ""

    # Last sync activity - show from the last "Starting Rsync job" to end of log
    echo -e "  ${BOLD}${WHITE}Last Sync${RESET}"
    echo -e "  ${DIM}$(printf '%.0s─' {1..45})${RESET}"
    if [ -f "$LOG_FILE" ]; then
        local start_line
        start_line=$(grep -n 'Starting Rsync job' "$LOG_FILE" | tail -1 | cut -d: -f1)
        if [ -n "$start_line" ]; then
            tail -n +"$start_line" "$LOG_FILE" | while IFS= read -r line; do
                if echo "$line" | grep -q 'completed successfully'; then
                    echo -e "  ${GREEN}$line${RESET}"
                elif echo "$line" | grep -q 'failed\|error\|ERROR'; then
                    echo -e "  ${RED}$line${RESET}"
                elif echo "$line" | grep -q '^deleting '; then
                    echo -e "  ${RED}− $line${RESET}"
                elif echo "$line" | grep -q '^\['; then
                    echo -e "  ${CYAN}$line${RESET}"
                elif echo "$line" | grep -q '^sent \|^total size'; then
                    echo -e "  ${DIM}$line${RESET}"
                elif echo "$line" | grep -q '^sending incremental'; then
                    echo -e "  ${DIM}$line${RESET}"
                elif [ -z "$line" ]; then
                    : # skip blank lines
                else
                    echo -e "  ${WHITE}+ $line${RESET}"
                fi
            done
        else
            echo -e "  ${DIM}No sync results found in log.${RESET}"
        fi
    else
        echo -e "  ${DIM}Log file not found.${RESET}"
    fi
    echo ""
}

# Display the status dashboard. If a refresh interval (seconds) is passed,
# loops with clear-and-redraw until interrupted with Ctrl+C.
show_status() {
    local interval="$1"

    if [ -n "$interval" ] && [ "$interval" -gt 0 ] 2>/dev/null; then
        # Watch mode: clear screen and redraw every N seconds
        trap 'echo ""; exit 0' INT
        while true; do
            clear
            render_status
            echo -e "  \033[2mRefreshing every ${interval}s - press Ctrl+C to stop\033[0m"
            sleep "$interval"
        done
    else
        render_status
    fi

    exit 0
}

# Recursively collect all descendant PIDs of a given PID.
# Walks /proc/*/status to find children, since QNAP lacks pkill -P.
# Results are stored in the global DESCENDANT_PIDS array (children first,
# so killing in order is bottom-up).
get_descendants() {
    local parent=$1
    local child
    for child in /proc/[0-9]*/status; do
        local cpid
        cpid=$(basename "$(dirname "$child")")
        local cppid
        cppid=$(awk '/^PPid:/ {print $2}' "$child" 2>/dev/null)
        if [ "$cppid" = "$parent" ]; then
            get_descendants "$cpid"
            DESCENDANT_PIDS+=("$cpid")
        fi
    done
}

# Stop a running daemon by reading its PID file and killing the entire
# process tree (daemon + pipe subshell + inotifywait + background syncs).
# Uses recursive PID walking because the pipe subshell may not share the
# daemon's process group, and kill -- -PGID would miss it.
stop_daemon() {
    if [ ! -f "$PID_FILE" ]; then
        echo "No running daemon found (PID file $PID_FILE does not exist)."
        exit 1
    fi
    local_pid=$(cat "$PID_FILE")
    if kill -0 "$local_pid" 2>/dev/null; then
        echo "Stopping daemon (PID $local_pid)..."
        # Collect all descendant PIDs (children, grandchildren, etc.)
        DESCENDANT_PIDS=()
        get_descendants "$local_pid"
        # Send SIGTERM to the entire tree at once - the daemon, pipe subshell,
        # inotifywait, and any background sync subshells all get the signal.
        # Killing all simultaneously avoids the daemon blocking on a wait()
        # for children that are already dead.
        kill "$local_pid" "${DESCENDANT_PIDS[@]}" 2>/dev/null
        # Wait for the daemon to exit - it may need a moment to run its
        # cleanup trap after the pipe breaks
        sleep 2
        if kill -0 "$local_pid" 2>/dev/null; then
            # Bash doesn't deliver SIGTERM while blocked in a foreground pipeline
            # wait, so SIGKILL is expected for the main daemon process
            DESCENDANT_PIDS=()
            get_descendants "$local_pid"
            for dpid in "${DESCENDANT_PIDS[@]}"; do
                kill -9 "$dpid" 2>/dev/null
            done
            kill -9 "$local_pid" 2>/dev/null
        fi
        rm -f "$PID_FILE"
        echo "Daemon stopped."
    else
        echo "Stale PID file (process $local_pid not running). Cleaning up."
        rm -f "$PID_FILE"
    fi
    exit 0
}

# Send a test email to verify SMTP configuration without waiting for a real failure.
test_email() {
    echo "Sending test email to $EMAIL_TO via $SMTP_SERVER..."
    send_alert "This is a test alert from qnap_realtime_sync.sh on $(hostname).

If you are reading this, the SMTP configuration is working correctly.

Timestamp: $(date '+%Y-%m-%d %H:%M:%S')
Server: $SMTP_SERVER
TLS: ${SMTP_TLS:-none}
Auth: $([ -n "$SMTP_USER" ] && echo "yes ($SMTP_USER)" || echo "no")"
    echo "Done. Check your inbox."
    exit 0
}

case "$1" in
    --help)       show_help ;;
    --status)     show_status "$2" ;;
    --stop)       stop_daemon ;;
    --test-email) test_email ;;
    --initial)
        # Verify password file exists to prevent rsync from pausing to ask for input
        if [ ! -f "$PASSWORD_FILE" ]; then
            echo "Error: Password file $PASSWORD_FILE not found! Exiting."
            exit 1
        fi
        echo "Running Initial Sync in interactive mode..."
        run_rsync "initial"
        echo "Initial sync finished. You can now start the daemon."
        exit 0
        ;;
    --daemon)
        # Fall through to daemon startup below
        ;;
    "")
        show_help
        ;;
    *)
        echo "Unknown option: $1"
        echo ""
        show_help
        ;;
esac

# --- Daemon Startup ---
# Re-exec ourselves in the background with nohup, then exit the foreground
# process. This lets the user simply run "/opt/etc/qnap_realtime_sync.sh --daemon"
# without wrapping it in nohup ... &.
if [ -z "$_QNAP_SYNC_DAEMONIZED" ]; then
    export _QNAP_SYNC_DAEMONIZED=1
    /opt/bin/nohup "$0" --daemon > /dev/null 2>&1 &
    echo "Daemon started in background (PID $!)."
    exit 0
fi

# Verify password file exists to prevent rsync from pausing to ask for input
if [ ! -f "$PASSWORD_FILE" ]; then
    echo "Error: Password file $PASSWORD_FILE not found! Exiting."
    exit 1
fi

# Prevent multiple daemon instances - check if one is already running
if [ -f "$PID_FILE" ]; then
    existing_pid=$(cat "$PID_FILE")
    if kill -0 "$existing_pid" 2>/dev/null; then
        echo "Daemon is already running (PID $existing_pid). Use --stop first."
        exit 1
    else
        echo "Removing stale PID file (process $existing_pid not running)."
        rm -f "$PID_FILE"
    fi
fi

# Write the PID file for this daemon instance.
# We use our own PID so --stop can find and kill us.
echo $$ > "$PID_FILE"

log_message "Starting QNAP Real-Time Sync Daemon (PID $$)..."

# Clean up stale state from a previous run and initialize stats counters
rm -f "$SYNC_PENDING" "$ERROR_LOG"
init_stats

# Do a quick startup sync to catch anything missed while the daemon was offline
run_rsync "daemon"

# Build the list of full paths to watch from SYNC_DIRS.
# Only directories that actually exist on disk are included - missing ones are
# logged as warnings (they may not have been created yet or could be typos).
#
# IMPORTANT: We watch individual SYNC_DIRS instead of the entire SOURCE_DIR.
# The QNAP volume root contains system directories (.qpkg/HybridBackup,
# .qpkg/QVPN, .samba/lock, etc.) that generate continuous filesystem events
# (~9 events/sec). If we watched the entire volume, these events would
# constantly reset the debounce timer, preventing rsync from ever firing.
WATCH_DIRS=()
for dir in "${SYNC_DIRS[@]}"; do
    if [ -d "$SOURCE_DIR/$dir" ]; then
        WATCH_DIRS+=("$SOURCE_DIR/$dir")
    else
        log_message "Warning: Configured sync directory '$dir' not found, skipping watch."
    fi
done

if [ ${#WATCH_DIRS[@]} -eq 0 ]; then
    log_message "Error: No valid directories to watch. Exiting."
    exit 1
fi

log_message "Watching ${#WATCH_DIRS[@]} directories for changes..."

# --- Event Loop ---
#
# inotifywait runs in monitor mode (-m) watching all WATCH_DIRS recursively (-r)
# in quiet mode (-q, suppresses the "Setting up watches" banner).
# It outputs one line per event, which is piped into the while-read loop.
#
# Debounce strategy (flag-file based):
#   The previous approach used kill-and-restart: each event killed the pending
#   sleep timer and spawned a new one. This fails when events arrive faster than
#   the debounce interval - the timer never completes and rsync never runs.
#
#   The current approach uses a flag file (SYNC_PENDING):
#     1. First event:  creates the flag file, spawns a background subshell that
#                      sleeps for DEBOUNCE_SECONDS, then runs rsync, then clears
#                      the flag.
#     2. Subsequent events while the flag exists:  silently ignored (a sync cycle
#                      is already in progress; rsync will pick up all changes).
#     3. Rsync completes: flag is removed. The next event starts a fresh cycle.
#
#   The flag stays up for the entire duration of sleep + rsync, preventing
#   overlapping rsync processes that would exhaust the TrueNAS connection limit.
/opt/bin/inotifywait -mrq \
    -e modify,attrib,close_write,move,create,delete \
    "${WATCH_DIRS[@]}" | while read -r line; do

    # Only start a new debounce+sync cycle if one is not already in progress
    if [ ! -f "$SYNC_PENDING" ]; then
        touch "$SYNC_PENDING"
        (
            # Ensure the flag is always cleaned up, even if the subshell is killed
            # by a signal (SIGHUP, SIGTERM, SIGPIPE). Without this trap, a killed
            # subshell leaves the flag file behind, permanently blocking all future
            # sync cycles until the daemon is restarted.
            trap 'rm -f "$SYNC_PENDING"' EXIT
            sleep "$DEBOUNCE_SECONDS"
            run_rsync "daemon"
        ) &
    fi
done