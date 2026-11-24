#!/usr/bin/env bash
# pmg_backup.sh
# =================================================================
# Proxmox Mail Gateway Backup Script with Rotation and Rsync
# Copyright (c) 2025-2026 Rámon van Raaij
# License: BSD-3-Clause
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
# =================================================================
# This script performs the following actions:
# 1. Loads configuration from an optional root-owned config file
#    (default /etc/pmg_backup.conf, or PMG_BACKUP_CONF).
# 2. Creates a backup of the PMG configuration using pmgbackup.
# 3. Rotates local backups, keeping a specified number of recent backups.
# 4. (Optional) Syncs the latest backup to a remote server via rsync over SSH.
# 5. (Optional) Rotates backups on the remote server.
# 6. Sends a failure email by default; a success email only with EMAIL_ON_SUCCESS=true.
# 7. Cleans up its temporary files on exit and exits with the run's code.
#
# Usage:
#   pmg_backup.sh [--config <path>|--config=<path>] [--test-email | -h|--help]
#
# Configuration defaults below can be overridden by the environment or by
# the root-owned config file (default /etc/pmg_backup.conf, or
# PMG_BACKUP_CONF). The config file is sourced in a subshell, and only the
# allow-listed scalar names are copied into the main shell with "printf -v";
# nothing the file runs or defines reaches the main shell.
# =================================================================

set -o errexit -o errtrace -o nounset -o pipefail

umask 077

# Script temp directory: captured before anything loads it, so a
# configuration file cannot move the script's own temporary files.
SCRIPT_TMPDIR="${TMPDIR:-/tmp}"

# ------------------------------------------------------------------
# Overridable configuration (environment or PMG_BACKUP_CONF).
# ------------------------------------------------------------------

PMG_BACKUP_CONF="${PMG_BACKUP_CONF:-/etc/pmg_backup.conf}"

MAX_BACKUPS="${MAX_BACKUPS:-5}"
BACKUP_DIR="${BACKUP_DIR:-/var/lib/pmg/backup}"
RSYNC_ENABLED="${RSYNC_ENABLED:-true}"
REMOTE_HOST="${REMOTE_HOST:-your.server.com}"
REMOTE_USER="${REMOTE_USER:-backup}"
REMOTE_DIR="${REMOTE_DIR:-/path/to/remote/backups}"
REMOTE_SSH_KEY="${REMOTE_SSH_KEY:-/root/.ssh/id_ed25519}"
REMOTE_MAX_BACKUPS="${REMOTE_MAX_BACKUPS:-90}"
EMAIL_ENABLED="${EMAIL_ENABLED:-true}"
EMAIL_ON_SUCCESS="${EMAIL_ON_SUCCESS:-false}"
FROM_ADDRESS="${FROM_ADDRESS:-"PMG Backup <noreply@example.com>"}"
RECIPIENT_ADDRESS="${RECIPIENT_ADDRESS:-admin@example.com}"
SENDMAIL_CMD="${SENDMAIL_CMD:-/usr/sbin/sendmail}"
LOG_FILE="${LOG_FILE:-/var/log/pmg_backup.log}"
LOG_TAIL_LINES="${LOG_TAIL_LINES:-200}"
PMGBACKUP_CMD="${PMGBACKUP_CMD:-pmgbackup}"
RSYNC_CMD="${RSYNC_CMD:-rsync}"
SSH_CMD="${SSH_CMD:-ssh}"

# ------------------------------------------------------------------
# Runtime state.
# ------------------------------------------------------------------

CONFIG_FILE=""
CONFIG_GIVEN=0
ACTION=""

NOTIFICATION_SENT=0
TEMP_OUTPUT_FILE=""
LATEST_BACKUP_FILE=""
FAILED_LINE=""
FAILED_CMD=""
FAILED_STEP="initialization"

CONF_SCALAR_NAMES=(
    "MAX_BACKUPS" "BACKUP_DIR" "RSYNC_ENABLED" "REMOTE_HOST" "REMOTE_USER"
    "REMOTE_DIR" "REMOTE_SSH_KEY" "REMOTE_MAX_BACKUPS" "EMAIL_ENABLED"
    "EMAIL_ON_SUCCESS" "FROM_ADDRESS" "RECIPIENT_ADDRESS" "SENDMAIL_CMD"
    "LOG_FILE" "LOG_TAIL_LINES" "PMGBACKUP_CMD" "RSYNC_CMD" "SSH_CMD"
)

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

# Returns 0 when the octal mode is group- or world-writable, 1 when safe.
is_group_or_world_writable() {
    local mode="$1" digits group others
    case "${mode}" in
        ""|*[!0-7]*) return 0 ;;
    esac
    digits="${mode}"
    while [ "${#digits}" -lt 3 ]; do
        digits="0${digits}"
    done
    while [ "${#digits}" -gt 3 ]; do
        digits="${digits#?}"
    done
    group="${digits:1:1}"
    others="${digits:2:1}"
    case "${group}" in
        2|3|6|7) return 0 ;;
    esac
    case "${others}" in
        2|3|6|7) return 0 ;;
    esac
    return 1
}

# Returns 0 when the candidate is a scalar config variable this script knows.
is_conf_variable() {
    local candidate="$1" name
    for name in "${CONF_SCALAR_NAMES[@]}"; do
        if [ "${candidate}" = "${name}" ]; then
            return 0
        fi
    done
    return 1
}

# Append a formatted line to LOG_FILE and TEMP_OUTPUT_FILE (no stdout/stderr).
# The redirection to the log file is quiet: a failing log file never aborts
# the run, and the line still reaches stdout or stderr and this run's temp output.
log_append_files() {
    local formatted="$1"
    if [ -n "${LOG_FILE:-}" ]; then
        printf '%s\n' "${formatted}" 2>/dev/null >> "${LOG_FILE}" || true
    fi
    if [ -n "${TEMP_OUTPUT_FILE:-}" ] && [ -f "${TEMP_OUTPUT_FILE}" ]; then
        printf '%s\n' "${formatted}" 2>/dev/null >> "${TEMP_OUTPUT_FILE}" || true
    fi
}

# Log a timestamped line to stdout, LOG_FILE and TEMP_OUTPUT_FILE.
log_line() {
    local formatted
    formatted="$(printf '[%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$1")"
    printf '%s\n' "${formatted}"
    log_append_files "${formatted}"
}

# Log a timestamped error line to stderr, LOG_FILE and TEMP_OUTPUT_FILE.
log_error() {
    local formatted
    formatted="$(printf '[%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$1")"
    printf '%s\n' "${formatted}" >&2
    log_append_files "${formatted}"
}

# Run a command, logging every line of its combined output, and return
# the exit code of the command itself (PIPESTATUS[0]).
run_logged_cmd() {
    local cmd_rc=0 line
    # Disable errexit and errtrace for the pipeline so a failing command still
    # has every output line logged and its own exit code is returned.
    set +o errexit +o errtrace
    "$@" 2>&1 | while IFS= read -r line; do
        log_line "${line}"
    done
    cmd_rc="${PIPESTATUS[0]}"
    set -o errexit -o errtrace
    return "${cmd_rc}"
}

# Load the root-owned config file safely (NUL-separated fd-3 pairs, no eval).
load_config_file() {
    local conf_file="${CONFIG_FILE}"
    if [ ! -e "${conf_file}" ]; then
        if [ "${CONFIG_GIVEN}" = "1" ]; then
            log_error "FATAL: configuration file not found: ${conf_file}"
            exit 1
        fi
        return 0
    fi
    if [ -L "${conf_file}" ]; then
        log_error "FATAL: configuration file ${conf_file} is a symbolic link; refusing."
        exit 1
    fi
    if [ ! -f "${conf_file}" ]; then
        log_error "FATAL: configuration path ${conf_file} is not a regular file; refusing."
        exit 1
    fi
    local stat_output owner mode
    stat_output="$(stat -c '%u %a' "${conf_file}" 2>/dev/null || true)"
    if [ -z "${stat_output}" ]; then
        log_error "FATAL: could not read the owner and mode of ${conf_file}; refusing."
        exit 1
    fi
    owner="${stat_output%% *}"
    mode="${stat_output##* }"
    if [ "${owner}" != "0" ]; then
        log_error "FATAL: configuration file ${conf_file} is not owned by uid 0; refusing."
        exit 1
    fi
    if is_group_or_world_writable "${mode}"; then
        log_error "FATAL: configuration file ${conf_file} is group- or world-writable (mode ${mode}); refusing."
        exit 1
    fi
    if ! bash -n "${conf_file}" >/dev/null 2>&1; then
        log_error "FATAL: configuration file ${conf_file} has a syntax error; refusing."
        exit 1
    fi
    # Read the file once, in a subshell, as NUL-separated pairs on fd 3.
    # Scalar values are applied with "printf -v". Nothing read from the
    # file is ever evaluated.
    local conf_result="" conf_status="" conf_name="" conf_value=""
    local -a conf_applied_names=() conf_applied_values=()
    conf_result="$(mktemp "${SCRIPT_TMPDIR}/pmg-backup-conf.XXXXXX" 2>/dev/null || true)"
    if [ -n "${conf_result}" ]; then
        (
            exec 3>"${conf_result}" >/dev/null 2>&1 </dev/null
            set +o errexit
            set -o nounset
            # shellcheck source=/dev/null
            . "${conf_file}"
            conf_status=$?
            printf '%s\0%s\0' __CONF_STATUS__ "${conf_status}" >&3
            for conf_name in "${CONF_SCALAR_NAMES[@]}"; do
                if [[ -v ${conf_name} ]]; then
                    printf '%s\0%s\0' "${conf_name}" "${!conf_name}" >&3
                fi
            done
        ) || true
        if [ -f "${conf_result}" ]; then
            while IFS= read -r -d '' conf_name && IFS= read -r -d '' conf_value; do
                case "${conf_name}" in
                    __CONF_STATUS__) conf_status="${conf_value}" ;;
                    *)
                        if is_conf_variable "${conf_name}"; then
                            conf_applied_names+=("${conf_name}")
                            conf_applied_values+=("${conf_value}")
                        fi
                        ;;
                esac
            done < "${conf_result}" || true
        fi
        rm -f "${conf_result}" 2>/dev/null || true
    else
        log_error "WARNING: could not create a temporary file for the result of ${conf_file}."
        while IFS= read -r -d '' conf_name && IFS= read -r -d '' conf_value; do
            case "${conf_name}" in
                __CONF_STATUS__) conf_status="${conf_value}" ;;
                *)
                    if is_conf_variable "${conf_name}"; then
                        conf_applied_names+=("${conf_name}")
                        conf_applied_values+=("${conf_value}")
                    fi
                    ;;
            esac
        done < <(
            exec 3>&1 >/dev/null 2>&1 </dev/null
            set +o errexit
            set -o nounset
            {
                # shellcheck source=/dev/null
                . "${conf_file}"
                conf_status=$?
                printf '%s\0%s\0' __CONF_STATUS__ "${conf_status}" >&3
                for conf_name in "${CONF_SCALAR_NAMES[@]}"; do
                    if [[ -v ${conf_name} ]]; then
                        printf '%s\0%s\0' "${conf_name}" "${!conf_name}" >&3
                    fi
                done
            } >/dev/null 2>&1
        )
    fi
    case "${conf_status}" in
        ""|*[!0-9]*|????*)
            log_error "FATAL: the configuration file ${conf_file} did not finish loading (an unset variable or an exit in it); fix it and run again."
            exit 1
            ;;
    esac
    local i
    for ((i = 0; i < ${#conf_applied_names[@]}; i++)); do
        printf -v "${conf_applied_names[i]}" '%s' "${conf_applied_values[i]}"
    done
    if [ "${conf_status}" -ne 0 ]; then
        log_error "WARNING: the last command of the configuration file ${conf_file} returned ${conf_status}; its settings are applied anyway."
    fi
    log_line "Loaded configuration file ${conf_file}."
}

# Validate configuration values.
validate_settings() {
    local v
    for v in MAX_BACKUPS REMOTE_MAX_BACKUPS LOG_TAIL_LINES; do
        case "${!v}" in
            ''|*[!0-9]*)
                log_error "FATAL: ${v} must be a whole number."
                exit 1
                ;;
        esac
    done
    if [ "${MAX_BACKUPS}" -lt 1 ]; then
        log_error "FATAL: MAX_BACKUPS must be at least 1."
        exit 1
    fi
    if [ "${REMOTE_MAX_BACKUPS}" -lt 1 ]; then
        log_error "FATAL: REMOTE_MAX_BACKUPS must be at least 1."
        exit 1
    fi
    case "${EMAIL_ENABLED}" in
        true|false) ;;
        *)
            log_error "FATAL: EMAIL_ENABLED must be exactly 'true' or 'false'."
            exit 1
            ;;
    esac
    case "${EMAIL_ON_SUCCESS}" in
        true|false) ;;
        *)
            log_error "FATAL: EMAIL_ON_SUCCESS must be exactly 'true' or 'false'."
            exit 1
            ;;
    esac
    case "${RSYNC_ENABLED}" in
        true|false) ;;
        *)
            log_error "FATAL: RSYNC_ENABLED must be exactly 'true' or 'false'."
            exit 1
            ;;
    esac
    case "${BACKUP_DIR}" in
        /*) ;;
        *)
            log_error "FATAL: BACKUP_DIR must be an absolute path."
            exit 1
            ;;
    esac
    if [[ "${RSYNC_ENABLED}" == "true" ]]; then
        case "${REMOTE_HOST}" in
            *[![:alnum:]._-]*)
                log_error "FATAL: REMOTE_HOST may only contain letters, digits and the characters . _ -."
                exit 1
                ;;
        esac
        case "${REMOTE_HOST}" in
            -*)
                log_error "FATAL: REMOTE_HOST must not start with '-'."
                exit 1
                ;;
        esac
        case "${REMOTE_USER}" in
            *[![:alnum:]._-]*)
                log_error "FATAL: REMOTE_USER may only contain letters, digits and the characters . _ -."
                exit 1
                ;;
        esac
        case "${REMOTE_USER}" in
            -*)
                log_error "FATAL: REMOTE_USER must not start with '-'."
                exit 1
                ;;
        esac
        case "${REMOTE_DIR}" in
            /*) ;;
            *)
                log_error "FATAL: REMOTE_DIR must be an absolute path."
                exit 1
                ;;
        esac
        case "${REMOTE_DIR}" in
            *[![:alnum:]._/+@-]*)
                log_error "FATAL: REMOTE_DIR may only contain letters, digits and the characters . _ / + @ -."
                exit 1
                ;;
        esac
        case "${REMOTE_SSH_KEY}" in
            *[![:alnum:]._/+@-]*)
                log_error "FATAL: REMOTE_SSH_KEY may only contain letters, digits and the characters . _ / + @ -."
                exit 1
                ;;
        esac
        if [ -n "${REMOTE_SSH_KEY}" ] && [ ! -r "${REMOTE_SSH_KEY}" ]; then
            log_error "FATAL: REMOTE_SSH_KEY is not readable."
            exit 1
        fi
    fi
}

# Print usage information to stdout.
usage() {
    printf '%s\n' "Usage: pmg_backup.sh [--config <path>|--config=<path>] [--test-email | -h|--help]"
    printf '%s\n' ""
    printf '%s\n' "Options:"
    printf '%s\n' "  --config <path>    Configuration file (default: /etc/pmg_backup.conf, or PMG_BACKUP_CONF)."
    printf '%s\n' "  --test-email       Send one test email via SENDMAIL_CMD and exit."
    printf '%s\n' "  -h, --help         Show this help and exit."
}

# Print a usage error message and usage to stderr, then exit 2.
usage_error() {
    if [ $# -gt 0 ]; then
        printf '%s\n' "$1" >&2
    fi
    usage >&2
    exit 2
}

# Parse CLI options. Supports --flag value and --flag=value; rejects
# missing or empty values with exit 2.
parse_cli() {
    CONFIG_FILE="${PMG_BACKUP_CONF}"
    CONFIG_GIVEN=0
    ACTION=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --config)
                shift
                if [ $# -eq 0 ]; then
                    usage_error "missing value for --config"
                fi
                if [ -z "$1" ]; then
                    usage_error "empty value for --config"
                fi
                CONFIG_FILE="$1"
                CONFIG_GIVEN=1
                shift
                ;;
            --config=*)
                CONFIG_FILE="${1#--config=}"
                if [ -z "${CONFIG_FILE}" ]; then
                    usage_error "empty value for --config"
                fi
                CONFIG_GIVEN=1
                shift
                ;;
            --test-email|-h|--help)
                if [ -n "${ACTION}" ]; then
                    usage_error "only one action flag is allowed"
                fi
                ACTION="$1"
                shift
                ;;
            -*)
                usage_error "unknown option: $1"
                ;;
            *)
                usage_error "unexpected argument: $1"
                ;;
        esac
    done
}

# ------------------------------------------------------------------
# Email notification (sendmail only).
# ------------------------------------------------------------------

# Send a failure email via SENDMAIL_CMD -t. The body names the failed step,
# exit code, host, log file and the tail of this run's output. A failed send
# is logged and does not change the exit code.
send_failure_email() {
    local exit_code="$1"
    local subject
    subject="PMG Backup FAILURE on $(hostname): ${FAILED_STEP} (exit ${exit_code})"
    if ! {
        printf 'From: %s\n' "${FROM_ADDRESS}"
        printf 'To: %s\n' "${RECIPIENT_ADDRESS}"
        printf 'Subject: %s\n' "${subject}"
        printf 'Date: %s\n' "$(date -R)"
        printf '\n'
        printf 'PMG backup failed.\n\n'
        printf 'Host: %s\n' "$(hostname)"
        printf 'Step: %s\n' "${FAILED_STEP:-unknown}"
        printf 'Command: %s\n' "${FAILED_CMD:-unknown}"
        printf 'Exit code: %s\n' "${exit_code}"
        printf 'Log file: %s\n' "${LOG_FILE:-}"
        printf 'Time (UTC): %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
        printf '\n--- Log tail (%s lines) ---\n' "${LOG_TAIL_LINES}"
        if [ -f "${TEMP_OUTPUT_FILE:-}" ] && [ -r "${TEMP_OUTPUT_FILE}" ]; then
            tail -n "${LOG_TAIL_LINES}" "${TEMP_OUTPUT_FILE}" 2>/dev/null || true
        else
            tail -n "${LOG_TAIL_LINES}" "${LOG_FILE}" 2>/dev/null || true
        fi
    } | "${SENDMAIL_CMD}" -t -oi; then
        log_error "ERROR: failure email could not be sent."
        return 1
    fi
}

# Send a success email via SENDMAIL_CMD -t.
send_success_email() {
    local subject
    subject="PMG Backup SUCCESS on $(hostname)"
    if ! {
        printf 'From: %s\n' "${FROM_ADDRESS}"
        printf 'To: %s\n' "${RECIPIENT_ADDRESS}"
        printf 'Subject: %s\n' "${subject}"
        printf 'Date: %s\n' "$(date -R)"
        printf '\n'
        printf 'PMG backup completed successfully.\n\n'
        printf 'Host: %s\n' "$(hostname)"
        printf 'Log file: %s\n' "${LOG_FILE:-}"
    } | "${SENDMAIL_CMD}" -t -oi; then
        log_error "ERROR: success email could not be sent."
        return 1
    fi
}

# Send a single test email via SENDMAIL_CMD -t; log an error and return 1 when the send fails.
send_test_email() {
    local subject
    subject="PMG Backup test email on $(hostname)"
    if ! {
        printf 'From: %s\n' "${FROM_ADDRESS}"
        printf 'To: %s\n' "${RECIPIENT_ADDRESS}"
        printf 'Subject: %s\n' "${subject}"
        printf 'Date: %s\n' "$(date -R)"
        printf '\n'
        printf 'This is a test email from pmg_backup.sh.\n'
    } | "${SENDMAIL_CMD}" -t -oi; then
        log_error "ERROR: test email could not be sent (step: test email)."
        return 1
    fi
}

# Idempotent error trap: the first failure wins.
handle_error() {
    local line_number="$1" command="$2"
    if [ -n "${FAILED_LINE:-}" ]; then
        return 0
    fi
    FAILED_LINE="${line_number}"
    FAILED_CMD="${command}"
    log_error "ERROR on line ${line_number}: command failed: ${command}"
    log_error "Failed step: ${FAILED_STEP:-unknown}"
}

# ------------------------------------------------------------------
# Actions
# ------------------------------------------------------------------

# Create the local PMG backup, log its output, parse the backup path and
# record it in LATEST_BACKUP_FILE.
create_local_backup() {
    local rc=0 line raw_output=""
    raw_output="$(mktemp "${SCRIPT_TMPDIR}/pmg-backup-raw.XXXXXX" 2>/dev/null)" || raw_output=""
    if [ -z "${raw_output}" ]; then
        log_error "FATAL: could not create a temp file in TMPDIR."
        exit 1
    fi
    "${PMGBACKUP_CMD}" backup > "${raw_output}" 2>&1 || rc=$?
    while IFS= read -r line; do
        [ -n "${line}" ] && log_line "${line}"
    done < "${raw_output}"
    LATEST_BACKUP_FILE="$(awk -F': ' '/starting backup to:/ {print $2}' "${raw_output}")"
    rm -f -- "${raw_output}" 2>/dev/null || true
    if [ "${rc}" -ne 0 ]; then
        log_error "ERROR: ${PMGBACKUP_CMD} backup failed with exit code ${rc}."
        exit "${rc}"
    fi
    if [ -z "${LATEST_BACKUP_FILE}" ] || [ ! -f "${LATEST_BACKUP_FILE}" ]; then
        log_error "FATAL: Could not determine backup file path or file does not exist."
        exit 1
    fi
    log_line "Successfully created backup: ${LATEST_BACKUP_FILE}"
}

# Rotate local backups, keeping the newest MAX_BACKUPS matching files.
rotate_local_backups() {
    local files_to_delete rc=0
    FAILED_STEP="rotate local backups"
    log_line "Rotating local backups in ${BACKUP_DIR}. Keeping last ${MAX_BACKUPS}."
    files_to_delete="$(find "${BACKUP_DIR}" -maxdepth 1 -type f -name "pmg-backup_*.tgz" -printf '%T@ %p\n' | sort -nr | tail -n +$((MAX_BACKUPS + 1)) | cut -d' ' -f2-)" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        log_error "ERROR: local backup rotation failed with exit code ${rc}."
        exit 1
    fi
    if [ -n "${files_to_delete}" ]; then
        log_line "The following old local backups will be deleted:"
        log_line "${files_to_delete}"
        echo "${files_to_delete}" | xargs -r rm -- || rc=$?
        if [ "${rc}" -ne 0 ]; then
            log_error "ERROR: failed to delete one or more old local backups."
            exit 1
        fi
        log_line "Old local backups have been deleted."
    else
        log_line "No old local backups to delete."
    fi
}

# Sync the latest backup to the remote host via rsync over SSH, then rotate
# remote backups keeping the newest REMOTE_MAX_BACKUPS files.
rsync_backup() {
    local latest_backup_file="$1" remote_cmd="" rc=0 ssh_key_opt=""
    FAILED_STEP="rsync to remote"
    if [ -n "${REMOTE_SSH_KEY}" ]; then
        ssh_key_opt="-i ${REMOTE_SSH_KEY}"
    fi
    log_line "Syncing backup to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}"
    run_logged_cmd "${RSYNC_CMD}" -a -e "${SSH_CMD} ${ssh_key_opt} -o StrictHostKeyChecking=accept-new -o BatchMode=yes" "${latest_backup_file}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        log_error "ERROR: rsync failed with exit code ${rc}. The local backup stays."
        exit "${rc}"
    fi
    log_line "Rsync completed successfully."
    remote_cmd="cd '${REMOTE_DIR}' && ls -1t pmg-backup_*.tgz | tail -n +$((REMOTE_MAX_BACKUPS + 1)) | xargs -r rm"
    log_line "Executing remote rotation command..."
    if [ -n "${REMOTE_SSH_KEY}" ]; then
        run_logged_cmd "${SSH_CMD}" -i "${REMOTE_SSH_KEY}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${REMOTE_USER}@${REMOTE_HOST}" "${remote_cmd}" || rc=$?
    else
        run_logged_cmd "${SSH_CMD}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${REMOTE_USER}@${REMOTE_HOST}" "${remote_cmd}" || rc=$?
    fi
    if [ "${rc}" -ne 0 ]; then
        log_error "ERROR: remote rotation failed with exit code ${rc}."
        exit "${rc}"
    fi
    log_line "Remote rotation completed successfully."
}

# Send at most one email for the run: a failure email on non-zero exit, or a
# success email on exit 0 only when EMAIL_ON_SUCCESS=true. Returns without
# sending if a notification was already sent.
send_notification_on_exit() {
    local exit_code="$1"
    if [ "${NOTIFICATION_SENT}" = "1" ]; then
        return 0
    fi
    NOTIFICATION_SENT=1
    if [ "${exit_code}" -ne 0 ]; then
        if [ "${EMAIL_ENABLED}" = "true" ]; then
            send_failure_email "${exit_code}" || true
        fi
    else
        if [ "${EMAIL_ENABLED}" = "true" ] && [ "${EMAIL_ON_SUCCESS}" = "true" ]; then
            send_success_email || true
        fi
    fi
}

# Run on EXIT: send at most one notification, remove temp files, and exit
# with the run's original exit code.
cleanup() {
    local exit_code=$?
    set +o errexit
    trap - ERR
    send_notification_on_exit "${exit_code}"
    if [ -n "${TEMP_OUTPUT_FILE:-}" ]; then
        rm -f -- "${TEMP_OUTPUT_FILE}" 2>/dev/null || true
    fi
    exit "${exit_code}"
}

# Parse CLI options, load and validate configuration, run the backup steps,
# and let cleanup send the notification and exit with the run's code.
main() {
    parse_cli "$@"

    case "${ACTION}" in
        -h|--help)
            usage
            exit 0
            ;;
    esac

    trap 'handle_error $LINENO "$BASH_COMMAND"' ERR
    trap cleanup EXIT

    if [ -z "${ACTION}" ]; then
        NOTIFICATION_SENT=0
        FAILED_STEP="initialization"
    elif [ "${ACTION}" = "--test-email" ]; then
        NOTIFICATION_SENT=1
        FAILED_STEP="test email"
    fi

    TEMP_OUTPUT_FILE="$(mktemp "${SCRIPT_TMPDIR}/pmg-backup-output.XXXXXX" 2>/dev/null)" || TEMP_OUTPUT_FILE=""

    load_config_file

    validate_settings

    case "${ACTION}" in
        --test-email)
            if ! send_test_email; then
                exit 1
            fi
            exit 0
            ;;
    esac

    # Pre-flight dependency checks.
    if ! command -v "${PMGBACKUP_CMD}" >/dev/null 2>&1; then
        log_error "FATAL: required command '${PMGBACKUP_CMD}' is not installed or not in PATH."
        exit 1
    fi
    if [[ "${EMAIL_ENABLED}" == "true" ]] && ! [ -x "${SENDMAIL_CMD}" ]; then
        log_error "FATAL: required command '${SENDMAIL_CMD}' is not executable."
        exit 1
    fi
    if [[ "${RSYNC_ENABLED}" == "true" ]]; then
        if ! command -v "${RSYNC_CMD}" >/dev/null 2>&1; then
            log_error "FATAL: required command '${RSYNC_CMD}' is not installed or not in PATH."
            exit 1
        fi
        if ! command -v "${SSH_CMD}" >/dev/null 2>&1; then
            log_error "FATAL: required command '${SSH_CMD}' is not installed or not in PATH."
            exit 1
        fi
    fi

    log_line "--- Starting PMG backup ---"

    FAILED_STEP="create local backup"
    create_local_backup

    FAILED_STEP="rotate local backups"
    rotate_local_backups

    if [[ "${RSYNC_ENABLED}" == "true" ]]; then
        FAILED_STEP="rsync to remote"
        rsync_backup "${LATEST_BACKUP_FILE}"
    fi

    log_line "PMG backup completed successfully."
}

main "$@"
