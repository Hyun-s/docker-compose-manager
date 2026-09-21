#!/usr/bin/env bash

# Run an exclusive GPU job while temporarily stopping local model containers.
# Exact container configurations are preserved because the same containers are
# stopped and started again; no Compose profile reconstruction is required.

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
CONTAINER_NAME="${VLLM_CONTAINER_NAME:-vllm-local-coder}"
EMBEDDING_CONTAINER_NAME="${EMBEDDING_CONTAINER_NAME:-dcm-embedding-bge-m3}"
EMBEDDING_API_PORT="${DCM_EMBEDDING_PORT:-8081}"
STATE_DIR="${GPU_JOB_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/local-claude-code}"
LOCK_FILE="$STATE_DIR/gpu-job.lock"
ACTIVE_FILE="$STATE_DIR/gpu-job.active"
LAST_FILE="$STATE_DIR/gpu-job.last"
DOCKER_BIN="${DOCKER_BIN:-docker}"
CURL_BIN="${CURL_BIN:-curl}"
POLL_SECONDS="${GPU_JOB_POLL_SECONDS:-2}"
READY_POLL_SECONDS="${GPU_JOB_READY_POLL_SECONDS:-5}"

show_help() {
    cat <<EOF
Temporarily stop the LLM and embedding server, run an exclusive GPU task, then
restore the exact model containers that were previously running.

Usage:
  $SCRIPT_NAME run [options] -- <command> [args...]
  $SCRIPT_NAME status
  $SCRIPT_NAME recover

Options for run:
  --drain-timeout SEC  Wait this long for active/queued requests (default: 900)
  --ready-timeout SEC  Wait this long for vLLM health after restart (default: 1800)
  --no-drain           Stop immediately instead of waiting for idle

Examples:
  $SCRIPT_NAME run -- ./train_lora.sh
  $SCRIPT_NAME run --drain-timeout 1800 -- docker compose -f finetune.yml up --abort-on-container-exit

The GPU command must stay in the foreground. The LLM is restored first, then the
embedding server, before this wrapper returns, including when the command fails
or receives SIGINT/SIGTERM.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 2
}

container_exists() {
    local name="$1"
    "$DOCKER_BIN" inspect "$name" >/dev/null 2>&1
}

container_running() {
    local name="$1"
    [[ "$("$DOCKER_BIN" inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]
}

find_api_port() {
    local port
    if [[ -n "${VLLM_API_PORT:-}" ]]; then
        printf '%s\n' "$VLLM_API_PORT"
        return 0
    fi
    for port in 8001 8000; do
        if "$CURL_BIN" -fsS --connect-timeout 1 --max-time 2 \
            "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
            printf '%s\n' "$port"
            return 0
        fi
    done
    return 1
}

metric_counts() {
    local port="$1" metrics
    metrics=$("$CURL_BIN" -fsS --connect-timeout 1 --max-time 3 \
        "http://127.0.0.1:${port}/metrics") || return 1
    awk '
        $1 ~ /^vllm:num_requests_running(\{|$)/ { running += $2 }
        $1 ~ /^vllm:num_requests_waiting(\{|$)/ { waiting += $2 }
        END { printf "%.0f %.0f\n", running + 0, waiting + 0 }
    ' <<<"$metrics"
}

wait_for_idle() {
    local port="$1" timeout="$2" deadline now running waiting quiet=0
    deadline=$(( $(date +%s) + timeout ))
    while true; do
        if ! read -r running waiting < <(metric_counts "$port"); then
            echo "Metrics endpoint is unavailable; proceeding with a graceful stop."
            return 0
        fi
        if (( running == 0 && waiting == 0 )); then
            quiet=$((quiet + 1))
            if (( quiet >= 2 )); then
                return 0
            fi
        else
            quiet=0
            echo "Waiting for vLLM to drain: running=$running waiting=$waiting"
        fi
        now=$(date +%s)
        (( now < deadline )) || return 1
        sleep "$POLL_SECONDS"
    done
}

wait_for_ready() {
    local timeout="$1" deadline port
    deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        if port=$(find_api_port); then
            echo "vLLM is ready on http://127.0.0.1:${port}"
            return 0
        fi
        if ! container_running "$CONTAINER_NAME"; then
            echo "vLLM container exited while restarting." >&2
            "$DOCKER_BIN" logs --tail 80 "$CONTAINER_NAME" >&2 || true
            return 1
        fi
        sleep "$READY_POLL_SECONDS"
    done
    echo "Timed out waiting for vLLM to become ready." >&2
    "$DOCKER_BIN" logs --tail 80 "$CONTAINER_NAME" >&2 || true
    return 1
}

wait_for_embedding_ready() {
    local timeout="$1" deadline
    deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        if "$CURL_BIN" -fsS --connect-timeout 1 --max-time 3 \
            "http://127.0.0.1:${EMBEDDING_API_PORT}/health" >/dev/null 2>&1; then
            echo "Embedding model is ready on http://127.0.0.1:${EMBEDDING_API_PORT}"
            return 0
        fi
        if ! container_running "$EMBEDDING_CONTAINER_NAME"; then
            echo "Embedding container exited while restarting." >&2
            "$DOCKER_BIN" logs --tail 80 "$EMBEDDING_CONTAINER_NAME" >&2 || true
            return 1
        fi
        sleep "$READY_POLL_SECONDS"
    done
    echo "Timed out waiting for the embedding model to become ready." >&2
    "$DOCKER_BIN" logs --tail 80 "$EMBEDDING_CONTAINER_NAME" >&2 || true
    return 1
}

write_state() {
    local file="$1" phase="$2" result="${3:-}" tmp
    tmp="${file}.tmp.$$"
    {
        printf 'pid=%s\n' "$$"
        printf 'phase=%s\n' "$phase"
        printf 'container=%s\n' "$CONTAINER_NAME"
        printf 'container_id=%s\n' "${CONTAINER_ID:-none}"
        printf 'vllm_was_running=%s\n' "${VLLM_WAS_RUNNING:-0}"
        printf 'embedding_container=%s\n' "$EMBEDDING_CONTAINER_NAME"
        printf 'embedding_container_id=%s\n' "${EMBEDDING_CONTAINER_ID:-none}"
        printf 'embedding_was_running=%s\n' "${EMBEDDING_WAS_RUNNING:-0}"
        printf 'started_at=%s\n' "${STARTED_AT:-unknown}"
        printf 'updated_at=%s\n' "$(date --iso-8601=seconds)"
        printf 'command=%s\n' "${COMMAND_DISPLAY:-none}"
        [[ -z "$result" ]] || printf 'result=%s\n' "$result"
    } >"$tmp"
    mv "$tmp" "$file"
}

show_status() {
    if [[ -f "$ACTIVE_FILE" ]]; then
        echo "Active GPU job:"
        cat "$ACTIVE_FILE"
    else
        echo "No active GPU job."
    fi
    if container_exists "$CONTAINER_NAME"; then
        "$DOCKER_BIN" inspect -f 'vllm_container={{.Name}} running={{.State.Running}} status={{.State.Status}}' \
            "$CONTAINER_NAME"
    else
        echo "vllm_container=$CONTAINER_NAME missing"
    fi
    if container_exists "$EMBEDDING_CONTAINER_NAME"; then
        "$DOCKER_BIN" inspect -f 'embedding_container={{.Name}} running={{.State.Running}} status={{.State.Status}}' \
            "$EMBEDDING_CONTAINER_NAME"
    else
        echo "embedding_container=$EMBEDDING_CONTAINER_NAME missing"
    fi
    if [[ -f "$LAST_FILE" ]]; then
        echo
        echo "Last GPU job:"
        cat "$LAST_FILE"
    fi
}

recover() {
    mkdir -p "$STATE_DIR"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "another GPU job/recovery operation holds $LOCK_FILE"
    if [[ ! -f "$ACTIVE_FILE" ]]; then
        echo "No interrupted GPU job state was found."
        return 0
    fi
    if grep -q '^vllm_was_running=1$' "$ACTIVE_FILE"; then
        container_exists "$CONTAINER_NAME" || die "$CONTAINER_NAME no longer exists"
        if ! container_running "$CONTAINER_NAME"; then
            echo "Restarting $CONTAINER_NAME from interrupted job state..."
            "$DOCKER_BIN" start "$CONTAINER_NAME" >/dev/null
        fi
        wait_for_ready "${GPU_JOB_READY_TIMEOUT:-1800}" || return 70
    fi
    if grep -q '^embedding_was_running=1$' "$ACTIVE_FILE"; then
        container_exists "$EMBEDDING_CONTAINER_NAME" || die "$EMBEDDING_CONTAINER_NAME no longer exists"
        if ! container_running "$EMBEDDING_CONTAINER_NAME"; then
            echo "Restarting $EMBEDDING_CONTAINER_NAME from interrupted job state..."
            "$DOCKER_BIN" start "$EMBEDDING_CONTAINER_NAME" >/dev/null
        fi
        wait_for_embedding_ready "${GPU_JOB_READY_TIMEOUT:-1800}" || return 70
    fi
    write_state "$LAST_FILE" recovered "recovered"
    python3 - "$ACTIVE_FILE" <<'PY'
import os, sys
try:
    os.unlink(sys.argv[1])
except FileNotFoundError:
    pass
PY
    echo "Recovery complete."
}

run_job() {
    local drain_timeout=900 ready_timeout=1800 drain=1
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --drain-timeout)
                [[ $# -ge 2 ]] || die "--drain-timeout requires seconds"
                drain_timeout="$2"; shift 2 ;;
            --ready-timeout)
                [[ $# -ge 2 ]] || die "--ready-timeout requires seconds"
                ready_timeout="$2"; shift 2 ;;
            --no-drain) drain=0; shift ;;
            --) shift; break ;;
            -h|--help) show_help; return 0 ;;
            *) die "unknown option: $1" ;;
        esac
    done
    [[ $# -gt 0 ]] || die "a foreground GPU command is required after --"
    [[ "$drain_timeout" =~ ^[0-9]+$ ]] || die "invalid drain timeout: $drain_timeout"
    [[ "$ready_timeout" =~ ^[0-9]+$ ]] || die "invalid ready timeout: $ready_timeout"

    command -v "$DOCKER_BIN" >/dev/null || die "$DOCKER_BIN is required"
    command -v "$CURL_BIN" >/dev/null || die "$CURL_BIN is required"
    command -v flock >/dev/null || die "flock is required"
    mkdir -p "$STATE_DIR"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "another exclusive GPU job is already active"

    STARTED_AT=$(date --iso-8601=seconds)
    COMMAND_DISPLAY=$(printf '%q ' "$@")
    CONTAINER_ID="none"
    EMBEDDING_CONTAINER_ID="none"
    VLLM_WAS_RUNNING=0
    EMBEDDING_WAS_RUNNING=0
    VLLM_RESTORE_NEEDED=0
    EMBEDDING_RESTORE_NEEDED=0
    READY_TIMEOUT="$ready_timeout"

    if container_exists "$CONTAINER_NAME"; then
        CONTAINER_ID=$("$DOCKER_BIN" inspect -f '{{.Id}}' "$CONTAINER_NAME")
        if container_running "$CONTAINER_NAME"; then
            VLLM_WAS_RUNNING=1
        fi
    fi
    if container_exists "$EMBEDDING_CONTAINER_NAME"; then
        EMBEDDING_CONTAINER_ID=$("$DOCKER_BIN" inspect -f '{{.Id}}' "$EMBEDDING_CONTAINER_NAME")
        if container_running "$EMBEDDING_CONTAINER_NAME"; then
            EMBEDDING_WAS_RUNNING=1
        fi
    fi

    cleanup() {
        local job_rc=$? restore_rc=0 final_rc result
        trap - EXIT INT TERM
        if (( VLLM_RESTORE_NEEDED == 1 )); then
            write_state "$ACTIVE_FILE" restoring
            echo "Restarting the exact previous vLLM container..."
            if ! container_running "$CONTAINER_NAME"; then
                "$DOCKER_BIN" start "$CONTAINER_NAME" >/dev/null || restore_rc=1
            fi
            if (( restore_rc == 0 )); then
                wait_for_ready "$READY_TIMEOUT" || restore_rc=1
            fi
        fi
        if (( EMBEDDING_RESTORE_NEEDED == 1 && restore_rc == 0 )); then
            write_state "$ACTIVE_FILE" restoring_embedding
            echo "Restarting the exact previous embedding container..."
            if ! container_running "$EMBEDDING_CONTAINER_NAME"; then
                "$DOCKER_BIN" start "$EMBEDDING_CONTAINER_NAME" >/dev/null || restore_rc=1
            fi
            if (( restore_rc == 0 )); then
                wait_for_embedding_ready "$READY_TIMEOUT" || restore_rc=1
            fi
        fi
        final_rc=$job_rc
        if (( restore_rc != 0 )); then
            echo "Model restoration failed; run: $SCRIPT_NAME recover" >&2
            (( final_rc != 0 )) || final_rc=70
            result="restore_failed:$final_rc"
            write_state "$ACTIVE_FILE" restore_failed "$result"
        else
            result="exit:$final_rc"
        fi
        write_state "$LAST_FILE" complete "$result"
        if (( restore_rc == 0 )); then
            python3 - "$ACTIVE_FILE" <<'PY'
import os, sys
try:
    os.unlink(sys.argv[1])
except FileNotFoundError:
    pass
PY
        fi
        exit "$final_rc"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    write_state "$ACTIVE_FILE" preparing
    if (( VLLM_WAS_RUNNING == 1 )); then
        local api_port=""
        api_port=$(find_api_port || true)
        if (( drain == 1 )) && [[ -n "$api_port" ]]; then
            write_state "$ACTIVE_FILE" draining
            echo "Waiting for vLLM requests to finish..."
            wait_for_idle "$api_port" "$drain_timeout" || {
                echo "vLLM did not become idle within ${drain_timeout}s; nothing was stopped." >&2
                exit 75
            }
        fi
    fi
    if (( EMBEDDING_WAS_RUNNING == 1 )); then
        write_state "$ACTIVE_FILE" stopping_embedding
        echo "Stopping $EMBEDDING_CONTAINER_NAME and releasing its GPU memory..."
        EMBEDDING_RESTORE_NEEDED=1
        if ! "$DOCKER_BIN" stop --time 60 "$EMBEDDING_CONTAINER_NAME" >/dev/null; then
            echo "Failed to stop $EMBEDDING_CONTAINER_NAME; refusing to start the GPU job." >&2
            exit 70
        fi
    else
        echo "Embedding model was not running; it will remain stopped after the GPU job."
    fi
    if (( VLLM_WAS_RUNNING == 1 )); then
        write_state "$ACTIVE_FILE" stopping_vllm
        echo "Stopping $CONTAINER_NAME and releasing GPU memory..."
        VLLM_RESTORE_NEEDED=1
        if ! "$DOCKER_BIN" stop --time 60 "$CONTAINER_NAME" >/dev/null; then
            echo "Failed to stop $CONTAINER_NAME; refusing to start the GPU job." >&2
            exit 70
        fi
    else
        echo "vLLM was not running; it will remain stopped after the GPU job."
    fi

    write_state "$ACTIVE_FILE" running_gpu_job
    echo "Running exclusive GPU command: $COMMAND_DISPLAY"
    "$@"
}

mkdir -p "$STATE_DIR"
case "${1:-}" in
    run) shift; run_job "$@" ;;
    status) show_status ;;
    recover) recover ;;
    help|-h|--help|"") show_help ;;
    *) die "unknown command: $1" ;;
esac
