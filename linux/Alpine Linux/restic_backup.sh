#!/usr/bin/env bash
# restic_backup.sh
# =================================================================
# Restic Backup Script for Alpine Linux
# Copyright (c) 2025-2026 Rámon van Raaij
# License: BSD-3-Clause
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
# =================================================================
# This script automates the backup of specified files, directories,
# and MariaDB databases to a Restic repository (B2, SFTP or REST).
#
# It performs the following actions:
# 1. Loads configuration from an optional root-owned config file and
#    secret environment files (no eval, no credentials on argv).
# 2. Takes an exclusive lock and prepares a safe, private staging directory.
# 3. Dumps MariaDB databases (MYSQL_PWD inline, never -p on the command line).
# 4. Backs up configured paths and the database dumps with Restic.
# 5. Applies the retention policy with 'restic forget --group-by host,tags --prune'.
# 6. Sends failure emails by default (success emails only with EMAIL_ON_SUCCESS=true).
# 7. Cleans up the staging directory and temporary files on exit.
#    A backup run ended by TERM, INT or HUP exits 143, 130 or 129 and
#    sends the failure email, unless the signal arrives once the run is
#    ending (while the email is being sent, or while the run removes its
#    files); then nothing more is sent, and the run removes its files
#    and ends with its own exit code. A --dry-run-prune or --test-email
#    run ended by a signal sends no failure email.
#
# Usage:
#   restic_backup.sh [--config <path>] [--method REST|B2|SFTP]
#                    [--dry-run-prune | --test-email | -h|--help]
#
# Configuration defaults below can be overridden by the environment or by
# the root-owned config file (default /etc/restic_backup.conf, or
# RESTIC_BACKUP_CONF). PATHS_TO_BACKUP is overridden from the config file
# with the __PATHS_DEFINED__ / __PATH_ITEM__ NUL-separated fd-3 emission.
# =================================================================

set -o errexit
set -o errtrace
set -o nounset
set -o pipefail

umask 077

# Script temp directory: captured before any restic environment file is
# loaded, so an env file that exports TMPDIR cannot move the script's own
# temporary files. Restic still inherits the configured TMPDIR.
SCRIPT_TMPDIR="${TMPDIR:-/tmp}"

# ------------------------------------------------------------------
# Overridable configuration (environment or RESTIC_BACKUP_CONF).
# ------------------------------------------------------------------

RESTIC_BACKUP_CONF="${RESTIC_BACKUP_CONF:-/etc/restic_backup.conf}"

BACKUP_METHOD="${BACKUP_METHOD:-SFTP}"
SFTP_SSH_KEY="${SFTP_SSH_KEY:-/root/.ssh/restic_key}"
LOG_FILE="${LOG_FILE:-/var/log/restic-backup.log}"
STAGING_DIR="${STAGING_DIR:-/var/lib/restic-backup/staging}"
LOCK_FILE="${LOCK_FILE:-/run/restic-backup.lock}"
EMAIL_ENABLED="${EMAIL_ENABLED:-true}"
EMAIL_ON_SUCCESS="${EMAIL_ON_SUCCESS:-false}"
FROM_ADDRESS="${FROM_ADDRESS:-LEMP Backup <backup@example.com>}"
RECIPIENT_ADDRESS="${RECIPIENT_ADDRESS:-admin@example.com}"
SENDMAIL_CMD="${SENDMAIL_CMD:-/usr/sbin/sendmail}"
LOG_TAIL_LINES="${LOG_TAIL_LINES:-200}"
DB_ENV_FILE="${DB_ENV_FILE:-}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-}"

if [[ ! -v PATHS_TO_BACKUP ]]; then
    PATHS_TO_BACKUP=(
        "/home/site1"
        "/home/site2"
        "/etc/nginx"
        "/etc/php83"
        "/etc/php84"
        "/var/spool/cron/crontabs"
        "/etc/apk/repositories"
        "/etc/periodic"
        "/etc/letsencrypt"
        "/etc/ssh/sshd_config"
        "/etc/sshguard.conf"
        "/etc/nftables.nft"
        "/etc/logrotate.d"
        "/usr/local/bin"
    )
fi

KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"
KEEP_YEARLY="${KEEP_YEARLY:-3}"

B2_ENV_FILE="${B2_ENV_FILE:-/root/.restic-b2.env}"
SFTP_ENV_FILE="${SFTP_ENV_FILE:-/root/.restic-sftp.env}"
REST_ENV_FILE="${REST_ENV_FILE:-/root/.restic-rest.env}"

RESTIC_CMD="${RESTIC_CMD:-restic}"
MARIADB_CMD="${MARIADB_CMD:-mariadb}"
MARIADB_DUMP_CMD="${MARIADB_DUMP_CMD:-mariadb-dump}"
APK_CMD="${APK_CMD:-apk}"
RC_UPDATE_CMD="${RC_UPDATE_CMD:-rc-update}"
SSH_CMD="${SSH_CMD:-ssh}" # Used for the SFTP connection test; restic itself runs ssh from PATH.
FLOCK_CMD="${FLOCK_CMD:-flock}"

# ------------------------------------------------------------------
# Runtime state.
# ------------------------------------------------------------------

CONFIG_FILE=""
CONFIG_GIVEN=0
METHOD_GIVEN=0
CLI_METHOD=""
ACTION=""

NOTIFICATION_SENT=0
SEND_NOTIFICATION_ON_EXIT=0
STAGING_DIR_ACTIVE=0
LOCK_ACQUIRED=0
LOCK_DIR=""
TEMP_OUTPUT_FILE=""
DB_ERR=""
RESTIC_EXTRA_OPTS=()
FAILED_LINE=""
FAILED_CMD=""
FAILED_STEP="initialization"

CONF_SCALAR_NAMES=(
    "BACKUP_METHOD" "SFTP_SSH_KEY" "LOG_FILE" "STAGING_DIR" "LOCK_FILE"
    "EMAIL_ENABLED" "EMAIL_ON_SUCCESS" "FROM_ADDRESS" "RECIPIENT_ADDRESS"
    "SENDMAIL_CMD" "LOG_TAIL_LINES" "DB_ENV_FILE" "DB_USER" "DB_PASSWORD"
    "KEEP_DAILY" "KEEP_WEEKLY" "KEEP_MONTHLY" "KEEP_YEARLY"
    "B2_ENV_FILE" "SFTP_ENV_FILE" "REST_ENV_FILE"
    "RESTIC_CMD" "MARIADB_CMD" "MARIADB_DUMP_CMD" "APK_CMD"
    "RC_UPDATE_CMD" "SSH_CMD" "FLOCK_CMD"
)

RESTIC_SECRET_NAMES=(
    "RESTIC_REPOSITORY" "RESTIC_PASSWORD" "RESTIC_PASSWORD_FILE"
    "RESTIC_PASSWORD_COMMAND" "RESTIC_REST_USERNAME" "RESTIC_REST_PASSWORD"
    "RESTIC_COMPRESSION" "RESTIC_CACHE_DIR" "TMPDIR"
    "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_DEFAULT_REGION"
    "B2_ACCOUNT_ID" "B2_ACCOUNT_KEY"
)

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

# Returns 0 when the octal mode is group- or world-writable, 1 when safe.
# Mode is printed without leading zeros by "stat", so it is padded.
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

# Returns 0 when the candidate is one of the allowed secret variables.
is_allowed_variable() {
    local candidate="$1" name
    shift
    for name in "$@"; do
        if [ "${candidate}" = "${name}" ]; then
            return 0
        fi
    done
    return 1
}

# Append a formatted line to LOG_FILE and TEMP_OUTPUT_FILE (no stdout/stderr).
log_append_files() {
    local formatted="$1"
    if [ -n "${LOG_FILE:-}" ]; then
        printf '%s\n' "${formatted}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
    if [ -n "${TEMP_OUTPUT_FILE:-}" ] && [ -f "${TEMP_OUTPUT_FILE}" ]; then
        printf '%s\n' "${formatted}" >> "${TEMP_OUTPUT_FILE}" 2>/dev/null || true
    fi
}

log_line() {
    local formatted
    formatted="$(printf '[%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$1")"
    printf '%s\n' "${formatted}"
    log_append_files "${formatted}"
}

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
    set +o errexit
    "$@" 2>&1 | while IFS= read -r line; do
        log_line "${line}"
    done
    cmd_rc="${PIPESTATUS[0]}"
    set -o errexit
    return "${cmd_rc}"
}

# Query MariaDB without leaking credentials on the command line.
# MYSQL_PWD is passed inline only when a password is configured, so
# unix_socket authentication keeps working with an empty password.
run_mariadb_query() {
    if [ -n "${DB_PASSWORD:-}" ]; then
        MYSQL_PWD="${DB_PASSWORD}" "${MARIADB_CMD}" -u "${DB_USER}" "$@"
    else
        "${MARIADB_CMD}" -u "${DB_USER}" "$@"
    fi
}

dump_single_db() {
    local db="$1" dest="$2"
    if [ -n "${DB_PASSWORD:-}" ]; then
        MYSQL_PWD="${DB_PASSWORD}" "${MARIADB_DUMP_CMD}" --user="${DB_USER}" --databases "${db}" > "${dest}"
    else
        "${MARIADB_DUMP_CMD}" --user="${DB_USER}" --databases "${db}" > "${dest}"
    fi
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
    if ! "${BASH}" -n "${conf_file}" >/dev/null 2>&1; then
        log_error "FATAL: configuration file ${conf_file} has a syntax error; refusing."
        exit 1
    fi
    # Read the file once, in a subshell, as NUL-separated pairs on fd 3.
    # Scalar values are applied with "printf -v"; PATHS_TO_BACKUP is
    # replaced when the file emits __PATHS_DEFINED__=1 plus one
    # __PATH_ITEM__ pair per path (the file may write those pairs to fd 3
    # while it is sourced). Nothing read from the file is ever evaluated.
    local conf_result="" conf_status="" conf_name="" conf_value=""
    local -a conf_applied_names=() conf_applied_values=() conf_path_items=()
    local conf_paths_defined=""
    conf_result="$(mktemp "${SCRIPT_TMPDIR}/restic-backup-conf.XXXXXX" 2>/dev/null || true)"
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
                    __PATHS_DEFINED__) conf_paths_defined="${conf_value}" ;;
                    __PATH_ITEM__) conf_path_items+=("${conf_value}") ;;
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
        log_error "WARNING: could not create a temporary file for the result of ${conf_file}; a compound background job in the configuration file can then delay this run."
        while IFS= read -r -d '' conf_name && IFS= read -r -d '' conf_value; do
            case "${conf_name}" in
                __CONF_STATUS__) conf_status="${conf_value}" ;;
                __PATHS_DEFINED__) conf_paths_defined="${conf_value}" ;;
                __PATH_ITEM__) conf_path_items+=("${conf_value}") ;;
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
    if [ "${conf_paths_defined}" = "1" ]; then
        PATHS_TO_BACKUP=()
        local item
        for item in "${conf_path_items[@]}"; do
            PATHS_TO_BACKUP+=("${item}")
        done
    fi
    if [ "${conf_status}" -ne 0 ]; then
        log_error "WARNING: the last command of the configuration file ${conf_file} returned ${conf_status}; its settings are applied anyway."
    fi
    log_line "Loaded configuration file ${conf_file}."
}

# Load a secret environment file, extracting only the allowed variables
# (NUL-separated fd-3 pairs, no eval). Variables are set but not exported;
# the caller exports the restic variables it wants restic to see.
load_secret_env_file() {
    local secret_file="$1" label="$2"
    shift 2
    local -a allowed_vars=("$@")

    if [ -L "${secret_file}" ]; then
        log_error "FATAL: secret file ${secret_file} is a symbolic link; refusing."
        exit 1
    fi
    if [ ! -e "${secret_file}" ]; then
        log_error "FATAL: secret file ${secret_file} does not exist; refusing."
        exit 1
    fi
    if [ ! -f "${secret_file}" ]; then
        log_error "FATAL: secret path ${secret_file} is not a regular file; refusing."
        exit 1
    fi
    local stat_output owner mode
    stat_output="$(stat -c '%u %a' "${secret_file}" 2>/dev/null || true)"
    if [ -z "${stat_output}" ]; then
        log_error "FATAL: could not read the owner and mode of ${secret_file}; refusing."
        exit 1
    fi
    owner="${stat_output%% *}"
    mode="${stat_output##* }"
    if [ "${owner}" != "$(id -u)" ]; then
        log_error "FATAL: secret file ${secret_file} is not owned by the current user; refusing."
        exit 1
    fi
    case "${mode}" in
        600|0600|400|0400) ;;
        *)
            log_error "FATAL: secret file ${secret_file} has mode ${mode}; expected 600 or 400."
            exit 1
            ;;
    esac
    if [ ! -r "${secret_file}" ]; then
        log_error "FATAL: secret file ${secret_file} is not readable; refusing."
        exit 1
    fi
    if ! "${BASH}" -n "${secret_file}" >/dev/null 2>&1; then
        log_error "FATAL: secret file ${secret_file} has a syntax error; refusing."
        exit 1
    fi
    # Read the file once, in a subshell, as NUL-separated pairs on fd 3.
    local secret_result="" secret_status="" secret_name="" secret_value=""
    local -a secret_applied_names=() secret_applied_values=()
    secret_result="$(mktemp "${SCRIPT_TMPDIR}/restic-backup-secret.XXXXXX" 2>/dev/null || true)"
    if [ -n "${secret_result}" ]; then
        (
            exec 3>"${secret_result}" >/dev/null 2>&1 </dev/null
            set +o errexit
            set -o nounset
            # shellcheck source=/dev/null
            . "${secret_file}"
            secret_status=$?
            printf '%s\0%s\0' __SECRET_STATUS__ "${secret_status}" >&3
            for secret_name in "${allowed_vars[@]}"; do
                if [[ -v ${secret_name} ]]; then
                    printf '%s\0%s\0' "${secret_name}" "${!secret_name}" >&3
                fi
            done
        ) || true
        if [ -f "${secret_result}" ]; then
            while IFS= read -r -d '' secret_name && IFS= read -r -d '' secret_value; do
                if [ "${secret_name}" = "__SECRET_STATUS__" ]; then
                    secret_status="${secret_value}"
                elif is_allowed_variable "${secret_name}" "${allowed_vars[@]}"; then
                    secret_applied_names+=("${secret_name}")
                    secret_applied_values+=("${secret_value}")
                fi
            done < "${secret_result}" || true
        fi
        rm -f "${secret_result}" 2>/dev/null || true
    else
        log_error "WARNING: could not create a temporary file for the result of ${secret_file}; a compound background job in the secret file can then delay this run."
        while IFS= read -r -d '' secret_name && IFS= read -r -d '' secret_value; do
            if [ "${secret_name}" = "__SECRET_STATUS__" ]; then
                secret_status="${secret_value}"
            elif is_allowed_variable "${secret_name}" "${allowed_vars[@]}"; then
                secret_applied_names+=("${secret_name}")
                secret_applied_values+=("${secret_value}")
            fi
        done < <(
            exec 3>&1 >/dev/null 2>&1 </dev/null
            set +o errexit
            set -o nounset
            {
                # shellcheck source=/dev/null
                . "${secret_file}"
                secret_status=$?
                printf '%s\0%s\0' __SECRET_STATUS__ "${secret_status}" >&3
                for secret_name in "${allowed_vars[@]}"; do
                    if [[ -v ${secret_name} ]]; then
                        printf '%s\0%s\0' "${secret_name}" "${!secret_name}" >&3
                    fi
                done
            } >/dev/null 2>&1
        )
    fi
    case "${secret_status}" in
        ""|*[!0-9]*|????*)
            log_error "WARNING: could not read the secret file ${secret_file}: it did not finish; ignoring it and continuing with the current settings."
            return 0
            ;;
    esac
    local i
    for ((i = 0; i < ${#secret_applied_names[@]}; i++)); do
        printf -v "${secret_applied_names[i]}" '%s' "${secret_applied_values[i]}"
    done
    if [ "${secret_status}" -ne 0 ]; then
        log_error "WARNING: the last command of the secret file ${secret_file} returned ${secret_status}; its settings are applied anyway."
    fi
    log_line "Loaded secret environment file ${secret_file} (${label})."
}

# Mask embedded credentials in a repository URL before logging or emailing.
sanitize_repo_url() {
    local url="$1"
    printf '%s' "${url}" | sed -E 's|(://)[^/]*@|\1<REDACTED>@|'
}

# Pass the SFTP key and ssh options to restic (restic has no environment variable for them).
set_restic_sftp_opts() {
    RESTIC_EXTRA_OPTS=(-o "sftp.args=-i ${SFTP_SSH_KEY} -o StrictHostKeyChecking=accept-new -o BatchMode=yes")
}

# Take an exclusive, non-blocking lock on LOCK_FILE (fd 9).
acquire_lock() {
    if [ -z "${LOCK_FILE}" ]; then
        log_error "FATAL: LOCK_FILE is empty."
        exit 1
    fi
    if [ -L "${LOCK_FILE}" ]; then
        log_error "FATAL: LOCK_FILE is a symbolic link: ${LOCK_FILE}."
        exit 1
    fi
    mkdir -p -- "$(dirname -- "${LOCK_FILE}")" 2>/dev/null || {
        log_error "FATAL: could not create the lock directory for ${LOCK_FILE}."
        exit 1
    }
    LOCK_ACQUIRED=0
    LOCK_DIR=""
    if command -v "${FLOCK_CMD}" >/dev/null 2>&1; then
        exec 9>"${LOCK_FILE}"
        if "${FLOCK_CMD}" -n 9; then
            LOCK_ACQUIRED=1
        else
            exec 9>&- 2>/dev/null || true
            log_error "FATAL: could not acquire the lock on ${LOCK_FILE}."
            exit 1
        fi
    else
        if mkdir "${LOCK_FILE}.d" 2>/dev/null; then
            LOCK_ACQUIRED=1
            LOCK_DIR="${LOCK_FILE}.d"
        else
            log_error "FATAL: could not acquire the lock on ${LOCK_FILE}."
            exit 1
        fi
    fi
}

# Validate and prepare the staging directory.
prepare_staging() {
    if [ -z "${STAGING_DIR}" ]; then
        log_error "FATAL: STAGING_DIR is empty."
        exit 1
    fi
    case "${STAGING_DIR}" in
        */|*//*|*/./*|*/../*|*/.|*/..)
            log_error "FATAL: STAGING_DIR '${STAGING_DIR}' must be a canonical absolute path (no trailing '/', '//', '.' or '..' components)."
            exit 1
            ;;
    esac
    case "${STAGING_DIR}" in
        /|/tmp|/var/tmp)
            log_error "FATAL: STAGING_DIR must not be '${STAGING_DIR}'."
            exit 1
            ;;
    esac
    if [[ "${STAGING_DIR}" != /* ]]; then
        log_error "FATAL: STAGING_DIR must be an absolute path: ${STAGING_DIR}."
        exit 1
    fi
    if [ -L "${STAGING_DIR}" ]; then
        log_error "FATAL: STAGING_DIR is a symbolic link: ${STAGING_DIR}."
        exit 1
    fi
    if [ -L "$(dirname -- "${STAGING_DIR}")" ]; then
        log_error "FATAL: the parent directory of STAGING_DIR is a symbolic link."
        exit 1
    fi
    mkdir -p -- "${STAGING_DIR}" 2>/dev/null || {
        log_error "FATAL: could not create ${STAGING_DIR}."
        exit 1
    }
    local owner
    owner="$(stat -c '%u' "${STAGING_DIR}" 2>/dev/null || true)"
    if [ "${owner}" != "$(id -u)" ]; then
        log_error "FATAL: ${STAGING_DIR} is not owned by the current user."
        exit 1
    fi
    chmod 700 "${STAGING_DIR}"
    find "${STAGING_DIR}" -mindepth 1 -exec rm -rf -- {} + 2>/dev/null || true
    STAGING_DIR_ACTIVE=1
}

# Validate configuration and CLI overrides.
validate_settings() {
    case "${BACKUP_METHOD}" in
        B2|SFTP|REST) ;;
        *)
            log_error "FATAL: invalid BACKUP_METHOD '${BACKUP_METHOD}'. Must be 'B2', 'SFTP', or 'REST'."
            exit 1
            ;;
    esac
    local v
    for v in KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY KEEP_YEARLY LOG_TAIL_LINES; do
        case "${!v}" in
            ''|*[!0-9]*)
                log_error "FATAL: ${v} must be a non-negative integer."
                exit 1
                ;;
        esac
    done
}

usage() {
    printf '%s\n' "Usage: restic_backup.sh [--config <path>] [--method REST|B2|SFTP] [--dry-run-prune | --test-email | -h|--help]"
    printf '%s\n' ""
    printf '%s\n' "Options:"
    printf '%s\n' "  --config <path>    Configuration file (default: /etc/restic_backup.conf, or RESTIC_BACKUP_CONF)."
    printf '%s\n' "  --method <method>  Override BACKUP_METHOD (REST, B2 or SFTP)."
    printf '%s\n' "  --dry-run-prune    Validate the restic env file and run 'restic forget --dry-run' only."
    printf '%s\n' "  --test-email       Send one test email via SENDMAIL_CMD and exit."
    printf '%s\n' "  -h, --help         Show this help and exit."
}

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
    CONFIG_FILE="${RESTIC_BACKUP_CONF}"
    CONFIG_GIVEN=0
    METHOD_GIVEN=0
    CLI_METHOD=""
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
            --method)
                shift
                if [ $# -eq 0 ]; then
                    usage_error "missing value for --method"
                fi
                if [ -z "$1" ]; then
                    usage_error "empty value for --method"
                fi
                CLI_METHOD="$1"
                METHOD_GIVEN=1
                shift
                ;;
            --method=*)
                CLI_METHOD="${1#--method=}"
                if [ -z "${CLI_METHOD}" ]; then
                    usage_error "empty value for --method"
                fi
                METHOD_GIVEN=1
                shift
                ;;
            --dry-run-prune|--test-email|-h|--help)
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

send_failure_email() {
    local exit_code="$1"
    local subject
    subject="Restic backup FAILED on $(hostname) (exit code ${exit_code})"
    {
        printf 'From: %s\n' "${FROM_ADDRESS}"
        printf 'To: %s\n' "${RECIPIENT_ADDRESS}"
        printf 'Subject: %s\n' "${subject}"
        printf 'Date: %s\n' "$(date -R)"
        printf 'MIME-Version: 1.0\n'
        printf 'Content-Type: text/plain; charset=UTF-8\n'
        printf '\n'
        printf 'Restic backup failed.\n\n'
        printf 'Host: %s\n' "$(hostname)"
        printf 'Method: %s\n' "${BACKUP_METHOD}"
        printf 'Repository: %s\n' "$(sanitize_repo_url "${RESTIC_REPOSITORY:-}")"
        printf 'Failed step: %s\n' "${FAILED_STEP:-unknown}"
        printf 'Failed line: %s\n' "${FAILED_LINE:-unknown}"
        printf 'Failed command: %s\n' "${FAILED_CMD:-unknown}"
        printf 'Exit code: %s\n' "${exit_code}"
        printf 'Log file: %s\n' "${LOG_FILE:-}"
        printf '\n--- Log tail (%s lines) ---\n' "${LOG_TAIL_LINES}"
        if [ -f "${TEMP_OUTPUT_FILE:-}" ] && [ -r "${TEMP_OUTPUT_FILE}" ]; then
            tail -n "${LOG_TAIL_LINES}" "${TEMP_OUTPUT_FILE}" 2>/dev/null || true
        else
            tail -n "${LOG_TAIL_LINES}" "${LOG_FILE}" 2>/dev/null || true
        fi
    } | "${SENDMAIL_CMD}" -t -oi
}

send_success_email() {
    local subject
    subject="Restic backup completed on $(hostname)"
    {
        printf 'From: %s\n' "${FROM_ADDRESS}"
        printf 'To: %s\n' "${RECIPIENT_ADDRESS}"
        printf 'Subject: %s\n' "${subject}"
        printf 'Date: %s\n' "$(date -R)"
        printf 'MIME-Version: 1.0\n'
        printf 'Content-Type: text/plain; charset=UTF-8\n'
        printf '\n'
        printf 'Restic backup completed successfully.\n\n'
        printf 'Host: %s\n' "$(hostname)"
        printf 'Method: %s\n' "${BACKUP_METHOD}"
        printf 'Repository: %s\n' "$(sanitize_repo_url "${RESTIC_REPOSITORY:-}")"
        printf 'Log file: %s\n' "${LOG_FILE:-}"
    } | "${SENDMAIL_CMD}" -t -oi
}

send_test_email() {
    local subject
    subject="Restic backup test email on $(hostname)"
    {
        printf 'From: %s\n' "${FROM_ADDRESS}"
        printf 'To: %s\n' "${RECIPIENT_ADDRESS}"
        printf 'Subject: %s\n' "${subject}"
        printf 'Date: %s\n' "$(date -R)"
        printf 'MIME-Version: 1.0\n'
        printf 'Content-Type: text/plain; charset=UTF-8\n'
        printf '\n'
        printf 'This is a test email from restic_backup.sh.\n'
    } | "${SENDMAIL_CMD}" -t -oi
}

# Idempotent error trap: the first failure wins.
handle_error() {
    local line_number="$1" command="$2"
    if [ -n "${FAILED_LINE:-}" ]; then
        return 0
    fi
    FAILED_LINE="${line_number}"
    FAILED_CMD="${command}"
    SEND_NOTIFICATION_ON_EXIT=1
    log_error "ERROR on line ${line_number}: command failed: ${command}"
    log_error "Failed step: ${FAILED_STEP:-unknown}"
}

# ------------------------------------------------------------------
# Actions
# ------------------------------------------------------------------

run_dry_run_prune() {
    local env_file
    case "${BACKUP_METHOD}" in
        B2)  env_file="${B2_ENV_FILE}" ;;
        SFTP) env_file="${SFTP_ENV_FILE}" ;;
        REST) env_file="${REST_ENV_FILE}" ;;
    esac
    if [ ! -f "${env_file}" ]; then
        log_error "FATAL: restic environment file not found: ${env_file}"
        return 1
    fi
    load_secret_env_file "${env_file}" "restic repository (${BACKUP_METHOD})" "${RESTIC_SECRET_NAMES[@]}"
    local v
    for v in "${RESTIC_SECRET_NAMES[@]}"; do
        if [[ -v ${v} ]]; then
            # shellcheck disable=SC2163
            export "${v}"
        fi
    done
    if [ -z "${RESTIC_REPOSITORY:-}" ]; then
        log_error "FATAL: RESTIC_REPOSITORY is not set in ${env_file}."
        return 1
    fi
    if [[ "${BACKUP_METHOD}" == "SFTP" ]]; then
        # restic splits its -o values on commas and the sftp.args value on
        # whitespace, so the key path is limited to letters, digits and . _ / + @ -
        # (letters as the locale defines them; restic keeps any of them in one word).
        case "${SFTP_SSH_KEY}" in
            *[![:alnum:]._/+@-]*)
                log_error "FATAL: SFTP_SSH_KEY may only contain letters, digits and the characters . _ / + @ - (restic splits sftp.args on whitespace and commas)."
                return 1
                ;;
        esac
        if [ ! -r "${SFTP_SSH_KEY}" ]; then
            log_error "FATAL: SFTP SSH key is not readable at: ${SFTP_SSH_KEY}"
            return 1
        fi
        local sftp_target
        sftp_target="$(printf '%s' "${RESTIC_REPOSITORY}" | sed -E 's|sftp:([^:]+):.*|\1|')"
        if ! "${SSH_CMD}" -q -i "${SFTP_SSH_KEY}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${sftp_target}" 'exit' >/dev/null 2>&1; then
            log_error "FATAL: SFTP connection test failed."
            return 1
        fi
    fi
    if [[ "${BACKUP_METHOD}" == "SFTP" ]]; then
        set_restic_sftp_opts
    fi
    log_line "Dry-run prune for repository $(sanitize_repo_url "${RESTIC_REPOSITORY}") (method ${BACKUP_METHOD})"
    if ! run_logged_cmd "${RESTIC_CMD}" "${RESTIC_EXTRA_OPTS[@]}" forget --group-by host,tags --keep-daily "${KEEP_DAILY}" --keep-weekly "${KEEP_WEEKLY}" --keep-monthly "${KEEP_MONTHLY}" --keep-yearly "${KEEP_YEARLY}" --dry-run; then
        SEND_NOTIFICATION_ON_EXIT=0
        return 1
    fi
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------

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
    # A run ended by a signal still runs cleanup: it removes the run's files,
    # and a backup run sends the failure email.
    trap 'exit 143' TERM
    trap 'exit 130' INT
    trap 'exit 129' HUP

    # Enable failure notification for a normal backup run before loading
    # configuration or validating settings, so an explicit 'exit 1' anywhere
    # in main() still sends one failure email. The dry-run and test-email
    # actions reset it to 0 below.
    if [ -z "${ACTION}" ]; then
        SEND_NOTIFICATION_ON_EXIT=1
    fi

    TEMP_OUTPUT_FILE="$(mktemp "${SCRIPT_TMPDIR}/restic-backup-output.XXXXXX" 2>/dev/null)" || TEMP_OUTPUT_FILE=""

    load_config_file

    if [ "${METHOD_GIVEN}" = "1" ]; then
        BACKUP_METHOD="${CLI_METHOD}"
    fi

    validate_settings

    case "${BACKUP_METHOD}" in
        B2)  RESTIC_ENV_FILE="${B2_ENV_FILE}" ;;
        SFTP) RESTIC_ENV_FILE="${SFTP_ENV_FILE}" ;;
        REST) RESTIC_ENV_FILE="${REST_ENV_FILE}" ;;
    esac

    case "${ACTION}" in
        --dry-run-prune)
            SEND_NOTIFICATION_ON_EXIT=0
            if ! run_dry_run_prune; then
                exit 1
            fi
            exit 0
            ;;
        --test-email)
            SEND_NOTIFICATION_ON_EXIT=0
            if ! send_test_email; then
                exit 1
            fi
            exit 0
            ;;
    esac

    log_line "--- Starting restic backup using ${BACKUP_METHOD} method ---"

    FAILED_STEP="lock"
    acquire_lock

    FAILED_STEP="staging"
    prepare_staging

    FAILED_STEP="loading credentials"
    load_secret_env_file "${RESTIC_ENV_FILE}" "restic repository (${BACKUP_METHOD})" "${RESTIC_SECRET_NAMES[@]}"
    local v
    for v in "${RESTIC_SECRET_NAMES[@]}"; do
        if [[ -v ${v} ]]; then
            # shellcheck disable=SC2163
            export "${v}"
        fi
    done

    if [ -n "${DB_ENV_FILE:-}" ]; then
        FAILED_STEP="loading database credentials"
        load_secret_env_file "${DB_ENV_FILE}" "database" DB_USER DB_PASSWORD
    fi

    if [ -z "${RESTIC_REPOSITORY:-}" ]; then
        log_error "FATAL: RESTIC_REPOSITORY is not set in ${RESTIC_ENV_FILE}."
        exit 1
    fi

    FAILED_STEP="dependency check"
    local cmd
    for cmd in "${RESTIC_CMD}" "${MARIADB_CMD}" "${MARIADB_DUMP_CMD}" "${APK_CMD}" "${SENDMAIL_CMD}"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            log_error "FATAL: required command '${cmd}' is not installed or not in PATH."
            exit 1
        fi
    done
    if [ "${BACKUP_METHOD}" = "SFTP" ]; then
        if ! command -v "${SSH_CMD}" >/dev/null 2>&1; then
            log_error "FATAL: required command '${SSH_CMD}' is not installed or not in PATH."
            exit 1
        fi
    fi

    if [[ "${BACKUP_METHOD}" == "SFTP" ]]; then
        # restic splits its -o values on commas and the sftp.args value on
        # whitespace, so the key path is limited to letters, digits and . _ / + @ -
        # (letters as the locale defines them; restic keeps any of them in one word).
        case "${SFTP_SSH_KEY}" in
            *[![:alnum:]._/+@-]*)
                log_error "FATAL: SFTP_SSH_KEY may only contain letters, digits and the characters . _ / + @ - (restic splits sftp.args on whitespace and commas)."
                exit 1
                ;;
        esac
        if [ ! -r "${SFTP_SSH_KEY}" ]; then
            log_error "FATAL: SFTP SSH key is not readable at: ${SFTP_SSH_KEY}"
            exit 1
        fi
        local sftp_target
        sftp_target="$(printf '%s' "${RESTIC_REPOSITORY}" | sed -E 's|sftp:([^:]+):.*|\1|')"
        if ! "${SSH_CMD}" -q -i "${SFTP_SSH_KEY}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes "${sftp_target}" 'exit' >/dev/null 2>&1; then
            log_error "FATAL: SFTP connection test failed."
            exit 1
        fi
    fi

    FAILED_STEP="mariadb connectivity"
    if ! run_mariadb_query -e "SELECT 1;" >/dev/null 2>&1; then
        log_error "FATAL: could not connect to MariaDB. Check credentials."
        exit 1
    fi

    FAILED_STEP="system state"
    log_line "Backing up system state..."
    "${APK_CMD}" info > "${STAGING_DIR}/packages.list"
    if command -v "${RC_UPDATE_CMD}" >/dev/null 2>&1; then
        "${RC_UPDATE_CMD}" show > "${STAGING_DIR}/services.list"
    else
        : > "${STAGING_DIR}/services.list"
    fi

    FAILED_STEP="mariadb dump"
    log_line "Dumping MariaDB databases..."
    local db_list db_list_rc=0
    local db_err="" db_err_text=""
    db_err="$(mktemp "${SCRIPT_TMPDIR}/restic-backup-err.XXXXXX" 2>/dev/null)" || db_err=""
    if [ -n "${db_err}" ]; then
        DB_ERR="${db_err}"
        db_list="$(run_mariadb_query -sN -e "SHOW DATABASES;" 2>"${db_err}")" || db_list_rc=$?
    else
        db_list="$(run_mariadb_query -sN -e "SHOW DATABASES;" 2>/dev/null)" || db_list_rc=$?
    fi
    if [ "${db_list_rc}" -ne 0 ]; then
        db_err_text="$(cat -- "${db_err}" 2>/dev/null || true)"
        if [ -n "${db_err_text}" ]; then
            log_error "FATAL: could not list MariaDB databases (exit ${db_list_rc}): ${db_err_text}"
        else
            log_error "FATAL: could not list MariaDB databases (exit ${db_list_rc}); no error output was captured."
        fi
        [ -n "${db_err}" ] && rm -f "${db_err}"
        DB_ERR=""
        exit 1
    fi
    if [ -n "${db_err}" ]; then
        while IFS= read -r err_line; do
            [ -n "${err_line}" ] || continue
            log_line "WARNING: mariadb: ${err_line}"
        done < "${db_err}"
        rm -f "${db_err}"
        DB_ERR=""
    fi
    db_list="$(printf '%s\n' "${db_list}" | grep -Ev '^(information_schema|performance_schema|mysql|sys)$' || true)"
    local db
    while IFS= read -r db; do
        [ -n "${db}" ] || continue
        case "${db}" in
            */*|-*)
                log_error "FATAL: MariaDB database name '${db}' cannot be backed up safely (it contains '/' or starts with '-'); rename the database."
                exit 1
                ;;
            .|..)
                log_error "FATAL: MariaDB database name '${db}' cannot be backed up safely (it is '.' or '..'); rename the database."
                exit 1
                ;;
        esac
    done <<< "${db_list}"
    while IFS= read -r db; do
        [ -n "${db}" ] || continue
        log_line "  - Dumping database: ${db}"
        if run_logged_cmd dump_single_db "${db}" "${STAGING_DIR}/${db}.sql"; then
            :
        else
            local rc=$?
            log_error "ERROR: mariadb dump failed with exit code ${rc}."
            exit "${rc}"
        fi
    done <<< "${db_list}"

    FAILED_STEP="restic backup"
    log_line "Starting Restic backup to $(sanitize_repo_url "${RESTIC_REPOSITORY}")..."
    if [[ "${BACKUP_METHOD}" == "SFTP" ]]; then
        set_restic_sftp_opts
    fi
    if run_logged_cmd "${RESTIC_CMD}" "${RESTIC_EXTRA_OPTS[@]}" backup --tag automated --tag "${BACKUP_METHOD}" --group-by host,tags --files-from <(printf '%s\n' "${PATHS_TO_BACKUP[@]}") "${STAGING_DIR}"; then
        :
    else
        local rc=$?
        log_error "ERROR: restic backup failed with exit code ${rc}."
        exit "${rc}"
    fi

    FAILED_STEP="restic prune"
    log_line "Pruning old snapshots according to retention policy..."
    if run_logged_cmd "${RESTIC_CMD}" "${RESTIC_EXTRA_OPTS[@]}" forget --group-by host,tags --keep-daily "${KEEP_DAILY}" --keep-weekly "${KEEP_WEEKLY}" --keep-monthly "${KEEP_MONTHLY}" --keep-yearly "${KEEP_YEARLY}" --prune; then
        :
    else
        local rc=$?
        log_error "ERROR: restic prune failed with exit code ${rc}."
        exit "${rc}"
    fi

    SEND_NOTIFICATION_ON_EXIT=1
    log_line "Backup and prune completed successfully."
}

# ------------------------------------------------------------------
# Cleanup and exit (always preserves the original exit code).
# ------------------------------------------------------------------

# Remove the staging directory and the temporary files of the run and
# release the lock.
# Parameters: none.
remove_run_files() {
    if [ "${STAGING_DIR_ACTIVE}" = "1" ]; then
        rm -rf -- "${STAGING_DIR}" 2>/dev/null || true
        STAGING_DIR_ACTIVE=0
    fi
    if [ -n "${TEMP_OUTPUT_FILE:-}" ]; then
        rm -f -- "${TEMP_OUTPUT_FILE}" 2>/dev/null || true
    fi
    if [ -n "${DB_ERR:-}" ] && [ -f "${DB_ERR}" ]; then
        rm -f -- "${DB_ERR}" 2>/dev/null || true
        DB_ERR=""
    fi
    if [ "${LOCK_ACQUIRED}" = "1" ]; then
        exec 9>&- 2>/dev/null || true
        if [ -n "${LOCK_DIR}" ]; then
            rmdir -- "${LOCK_DIR}" 2>/dev/null || true
        fi
        LOCK_ACQUIRED=0
    fi
}

cleanup() {
    local exit_code=$?
    set +o errexit
    trap - ERR
    # A signal while the run is ending removes the run's files and ends the
    # run with its own exit code; nothing more is sent.
    trap 'remove_run_files; exit "${exit_code}"' TERM
    trap 'remove_run_files; exit "${exit_code}"' INT
    trap 'remove_run_files; exit "${exit_code}"' HUP

    if [ "${SEND_NOTIFICATION_ON_EXIT}" = "1" ] && [ "${NOTIFICATION_SENT}" = "0" ]; then
        NOTIFICATION_SENT=1
        if [ "${exit_code}" -ne 0 ]; then
            if [ "${EMAIL_ENABLED}" = "true" ]; then
                send_failure_email "${exit_code}"
            fi
        else
            if [ "${EMAIL_ENABLED}" = "true" ] && [ "${EMAIL_ON_SUCCESS}" = "true" ]; then
                send_success_email
            fi
        fi
    fi

    remove_run_files

    exit "${exit_code}"
}

main "$@"
