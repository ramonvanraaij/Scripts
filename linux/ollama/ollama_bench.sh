#!/usr/bin/env bash
# ollama_bench.sh
# =================================================================
# Ollama API Benchmark Script
#
# Copyright (c) 2025 Rámon van Raaij
# License: MIT
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# This script benchmarks the performance of a model served by the
# Ollama API (/api/generate endpoint). It runs a specified prompt
# multiple times and calculates metrics like Time To First Token (TTFT),
# prefill speed, and decode speed.
#
# The output table format is inspired by the `openarc bench` tool.
# Attribution: Output style based on openarc bench created by
# Emerson Tatelbaum (SearchSavior), licensed under OpenArc License.
# See: https://github.com/SearchSavior/OpenArc/blob/main/LICENSE
#
# --- Setup ---
# 1. Dependencies: Ensure `curl`, `jq`, `awk`, and `tput` are installed.
#    - Arch: sudo pacman -S curl jq gawk ncurses
#    - Debian/Ubuntu: sudo apt update && sudo apt install curl jq gawk ncurses-bin
#
# 2. Ollama Server: Make sure your Ollama server is running and
#    accessible at the configured API endpoint. Run `ollama serve` if needed.
#
# 3. Permissions: Make the script executable:
#    chmod +x ollama_bench.sh
#
# --- Usage ---
# Run with -h to see the options.
#   ./ollama_bench.sh -m llama3:latest -r 10
#
# To run interactively with defaults, run without any flags:
#   ./ollama_bench.sh
# =================================================================

# --- Script Configuration ---
# Exit on error, treat unset variables as an error, and fail on piped command errors.
set -o errexit -o nounset -o pipefail

# =================================================================
# --- Default Configuration ---
# These can be overridden with command-line flags.
# =================================================================
MODEL="qwen3:8b-q4_K_M"
PROMPT="Write a short story about a tulip seller in Amsterdam who finds a 17th-century painting."
RUNS=5
NUM_PREDICT=256
TEMPERATURE=0.0
TOP_K=1
OLLAMA_HOST="localhost:11434"

# =================================================================
# --- Do Not Edit Below This Line ---
# =================================================================

# --- Define color variables for styled terminal output ---
readonly GREEN=$(tput setaf 2)
readonly RED=$(tput setaf 1)
readonly YELLOW=$(tput setaf 3)
readonly NORMAL=$(tput sgr0)

# --- Functions ---

# Logs a message to the console with color.
log_message() {
    local color="$1"
    local message="$2"
    # No timestamp needed for this interactive script's output.
    printf "${color}%s${NORMAL}\n" "$message"
}

# Displays the help message.
usage() {
    cat <<EOF
Usage: ./ollama_bench.sh [OPTIONS]

A script to benchmark the performance of an Ollama model.

Options:
  -m MODEL          The Ollama model name to benchmark.
                    Default: ${MODEL}
  -p PROMPT         The prompt to send to the model.
                    Default: "${PROMPT:0:50}..."
  -r RUNS           Number of times to run the benchmark.
                    Default: ${RUNS}
  -n NUM_PREDICT    Maximum number of tokens to generate.
                    Default: ${NUM_PREDICT}
  -t TEMPERATURE    Generation temperature.
                    Default: ${TEMPERATURE}
  -k TOP_K          Top-K sampling.
                    Default: ${TOP_K}
  -H OLLAMA_HOST    The Ollama host and port.
                    Default: ${OLLAMA_HOST}
  -h                Display this help message.
EOF
}


# --- Main script logic ---
main() {
    # --- 1. Pre-flight Checks ---
    local dependencies="curl jq awk tput"
    for cmd in $dependencies; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_message "${RED}" "FATAL: Required command '${cmd}' is not installed or not in PATH."
            exit 1
        fi
    done

    # --- 2. Prepare Request Body ---
    local OLLAMA_API="http://${OLLAMA_HOST}/api/generate"
    local REQUEST_BODY
    REQUEST_BODY=$(cat <<EOF
{
  "model": "${MODEL}",
  "prompt": "${PROMPT}",
  "stream": false,
  "options": {
    "num_predict": ${NUM_PREDICT},
    "temperature": ${TEMPERATURE},
    "top_k": ${TOP_K}
  },
  "keep_alive": "0m"
}
EOF
)

        # --- 3. Benchmark Loop ---

        log_message "${YELLOW}" "Starting Ollama Benchmark for ${MODEL}..."

        echo "working..."

        echo # Add a newline to make space for the progress bar

    

        local results=()

        local prompt_eval_count_val=0

    

        tput sc # Save cursor position

    

        for i in $(seq 1 $RUNS); do

            tput rc # Restore cursor position

            tput el # Clear the line

            printf "${YELLOW}  benching... (%d/%d)${NORMAL}" "$i" "$RUNS"

    

            local JSON_OUTPUT

            JSON_OUTPUT=$(curl -sS -X POST "${OLLAMA_API}" -d "${REQUEST_BODY}" -H "Content-Type: application/json")
        if [ $? -ne 0 ]; then
            printf "%80s" " " # Clear progress line
            log_message "${RED}" "\nERROR: Curl command failed. Is Ollama running at ${OLLAMA_API}?"
            exit 1 # Exit on curl failure
        fi

        # Extract metrics
        local TOTAL_DURATION_NS PROMPT_EVAL_DURATION_NS EVAL_DURATION_NS PROMPT_EVAL_COUNT EVAL_COUNT
        TOTAL_DURATION_NS=$(echo "$JSON_OUTPUT" | jq '.total_duration // 0')
        PROMPT_EVAL_DURATION_NS=$(echo "$JSON_OUTPUT" | jq '.prompt_eval_duration // 0')
        EVAL_DURATION_NS=$(echo "$JSON_OUTPUT" | jq '.eval_duration // 0')
        PROMPT_EVAL_COUNT=$(echo "$JSON_OUTPUT" | jq '.prompt_eval_count // 0')
        EVAL_COUNT=$(echo "$JSON_OUTPUT" | jq '.eval_count // 0')

        # Validate metrics
        local all_metrics=("$TOTAL_DURATION_NS" "$PROMPT_EVAL_DURATION_NS" "$EVAL_DURATION_NS" "$PROMPT_EVAL_COUNT" "$EVAL_COUNT")
        local metrics_valid=true
        for metric in "${all_metrics[@]}"; do
             if ! [[ "$metric" =~ ^[0-9]+$ ]]; then
                 log_message "${RED}" "\nERROR: Failed to parse numeric metric. Value: '$metric'"
                 echo "Raw Response: $JSON_OUTPUT" >&2
                 metrics_valid=false
             fi
        done

        if [ "$metrics_valid" = true ]; then
            results+=("$i $PROMPT_EVAL_COUNT $EVAL_COUNT $PROMPT_EVAL_DURATION_NS $EVAL_DURATION_NS $TOTAL_DURATION_NS")
            if [ "$prompt_eval_count_val" -eq 0 ]; then
                prompt_eval_count_val=$PROMPT_EVAL_COUNT
            fi
        else
            # Add a placeholder for the failed run
            results+=("$i ERROR ERROR ERROR ERROR ERROR")
        fi
    done

    # --- 4. Print Results ---
    printf "%80s" " " # Clear progress line

    # Print summary
    echo
    echo "input tokens: [${prompt_eval_count_val}]"
    echo "max tokens:   [${NUM_PREDICT}]"
    echo "runs: ${RUNS}"
    echo
    echo "${GREEN}${MODEL}${NORMAL}"
    echo

    # Print table header
    echo "┏━━━━━┳━━━━━┳━━━━━┳━━━━━━━━━┳━━━━━━━━━━┳━━━━━━━━━━━━━━┳━━━━━━━━━━━━━┳━━━━━━━━━━━━━┓"
    echo "┃ run ┃   p ┃   n ┃ ttft(s) ┃ tpot(ms) ┃ prefill(t/s) ┃ decode(t/s) ┃ duration(s) ┃"
    echo "┡━━━━━╇━━━━━╇━━━━━╇━━━━━━━━━╇━━━━━━━━━━╇━━━━━━━━━━━━━━╇━━━━━━━━━━━━━╇━━━━━━━━━━━━━┩"

    # Print table rows
    for result_line in "${results[@]}"; do
        read -r i p n prompt_eval_ns eval_ns total_ns <<< "$result_line"

        if [ "$p" = "ERROR" ]; then
            LC_ALL=C printf "│ %3s │ %3s │ %3s │ %7s │ %8s │ %12s │ %11s │ %11s │\n" "$i" "ERR" "ERR" "ERR" "ERR" "ERR" "ERR" "ERR"
            continue
        fi

        # Calculate Rates
        local TTFT_S TPOT_MS PREFILL_RATE DECODE_RATE DURATION_S
        TTFT_S=$(LC_ALL=C awk "BEGIN {printf \"%.2f\", ${prompt_eval_ns} / 1000000000}")
        TPOT_MS=$(LC_ALL=C awk "BEGIN {if ($n > 0) printf \"%.2f\", (${eval_ns} / 1000000) / $n; else print \"0.00\"}")
        PREFILL_RATE=$(LC_ALL=C awk "BEGIN {if ($prompt_eval_ns > 0) printf \"%.1f\", $p * 1000000000 / $prompt_eval_ns; else print \"0.0\"}")
        DECODE_RATE=$(LC_ALL=C awk "BEGIN {if ($eval_ns > 0) printf \"%.1f\", $n * 1000000000 / $eval_ns; else print \"0.0\"}")
        DURATION_S=$(LC_ALL=C awk "BEGIN {printf \"%.2f\", ${total_ns} / 1000000000}")

        # Print results row
        LC_ALL=C printf "│ %3d │ %3d │ %3d │ %7.2f │ %8.2f │ %12.1f │ %11.1f │ %11.2f │\n" "$i" "$p" "$n" "$TTFT_S" "$TPOT_MS" "$PREFILL_RATE" "$DECODE_RATE" "$DURATION_S"
    done

    # Print table footer
    echo "└─────┴─────┴─────┴─────────┴──────────┴──────────────┴─────────────┴─────────────┘"
    log_message "${GREEN}" "Total: ${RUNS} runs completed."
}

# --- Argument Parsing ---
if [ $# -eq 0 ]; then
    usage
    echo
    log_message "${YELLOW}" "No flags provided. Do you want to run with the default settings?"
    echo "--------------------------------------------------"
    echo "Model:          ${MODEL}"
    echo "Prompt:         ${PROMPT:0:50}..."
    echo "Runs:           ${RUNS}"
    echo "Max Tokens:     ${NUM_PREDICT}"
    echo "Temperature:    ${TEMPERATURE}"
    echo "Top-K:          ${TOP_K}"
    echo "Ollama Host:    ${OLLAMA_HOST}"
    echo "--------------------------------------------------"
    read -p "Continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY]([eE][sS])?$ ]]; then
        log_message "${RED}" "Aborted."
        exit 0
    fi
    echo
fi

while getopts ":m:p:r:n:t:k:H:h" opt; do
    case ${opt} in
        m) MODEL=${OPTARG} ;; 
        p) PROMPT=${OPTARG} ;; 
        r) RUNS=${OPTARG} ;; 
        n) NUM_PREDICT=${OPTARG} ;; 
        t) TEMPERATURE=${OPTARG} ;; 
        k) TOP_K=${OPTARG} ;; 
        H) OLLAMA_HOST=${OPTARG} ;; 
        h) 
            usage
            exit 0
            ;; 
        ?) 
            log_message "${RED}" "Invalid option: -${OPTARG}" >&2
            usage
            exit 1
            ;; 
        :) 
            log_message "${RED}" "Option -${OPTARG} requires an argument." >&2
            usage
            exit 1
            ;; 
    esac
done

# --- Execute Main Function ---
main