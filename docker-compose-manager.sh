#!/bin/bash

# Docker Compose Manager for local model services
# Usage: ./docker-compose-manager.sh [up|down|status|restart|logs|ps|model|gpu-job] [config-name]
#        dcm [command] [config] [options]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMBEDDING_COMPOSE_FILE="docker-compose.embedding.yml"
EMBEDDING_MODEL="${DCM_EMBEDDING_MODEL:-BAAI/bge-m3}"
EMBEDDING_MODEL_REVISION="${DCM_EMBEDDING_MODEL_REVISION:-5617a9f61b028005a4858fdac845db406aefb181}"
EMBEDDING_MODEL_ALIAS="${DCM_EMBEDDING_MODEL_ALIAS:-bge-m3}"
EMBEDDING_PORT="${DCM_EMBEDDING_PORT:-8081}"
MODEL_READY_TIMEOUT="${DCM_MODEL_READY_TIMEOUT:-1800}"
MODEL_READY_POLL_SECONDS="${DCM_MODEL_READY_POLL_SECONDS:-5}"
CONFIGS=(
    "default:docker-compose.yml"
    "qwen35-122b:docker-compose.qwen35-122b.yml"
    "qwen38-27b:docker-compose.qwen38-27b.yml"
    "qwen38-flash-next:docker-compose.qwen38-flash-next.yml"
)

show_help() {
    cat << EOF
Docker Compose Manager for vllm services

Usage:
  $0 <command> [config] [options]
  dcm <command> [config] [options]

Commands:
  setup    Build/download models that require a one-time setup
  up       Start the service
  down     Stop the service
  status   Show service status
  restart  Restart the service
  logs     Show logs (options: -f for follow, -n <lines> for last N lines)
  ps       Show running vllm containers
  model    Manage the LLM + BGE-M3 embedding stack (up/down/status/logs)
  gpu-job  Stop vLLM, run an exclusive GPU task, then restore vLLM
  h, help  Show this help message

Configs:
  default        - docker-compose.yml (official vLLM nightly, Qwen3-Coder-Next-FP8)
  qwen35-122b    - docker-compose.qwen35-122b.yml (local image, Qwen3.5-122B hybrid INT4+FP8)
  qwen38-27b     - docker-compose.qwen38-27b.yml (official Qwen3.8-27B BF16)
  qwen38-flash-next - docker-compose.qwen38-flash-next.yml (NVFP4 + NVMe PLE offload)

Environment Variables:
  HF_TOKEN       Hugging Face token (used when a config downloads a model)
                 Set in ~/.bashrc: export HF_TOKEN="your_token_here"

Options for logs:
  -f             Follow log output
  -n <lines>     Show last N lines of logs

Options for qwen38-27b and qwen38-flash-next (up, restart):
  --text-only    Skip the vision encoder to save memory
  --vision       Load the vision encoder for image/video inputs

Examples:
  $0 up                    # Start default service
  $0 up qwen35-122b        # Start qwen35-122b service
  $0 up qwen38-27b         # Start Qwen3.8 in text-only mode
  $0 up qwen38-27b --vision # Start Qwen3.8 with the vision encoder
  $0 setup qwen38-flash-next # Build runtime and download the checkpoint
  $0 up qwen38-flash-next  # Start Flash-Next with image/video support
  $0 up qwen38-flash-next --text-only # Start Flash-Next without vision
  $0 down                  # Stop default service
  $0 down qwen35-122b      # Stop qwen35-122b service
  $0 status                # Check default service status
  $0 logs -f               # Follow default service logs
  $0 logs -f qwen35-122b   # Follow qwen35-122b service logs
  $0 logs -n 50            # Show last 50 lines of default service logs
  $0 ps                    # Show all vllm containers
  $0 model up qwen38-flash-next --vision
  $0 model status qwen38-flash-next
  $0 model down qwen38-flash-next
  $0 gpu-job run -- ./train_lora.sh
  $0 gpu-job status
  $0 gpu-job recover       # Restore vLLM after an interrupted/killed wrapper

Note: When using alias 'dcm', replace '$0' with 'dcm' in examples.
EOF
}

show_model_help() {
    cat << EOF
Manage the local LLM and BGE-M3 embedding servers as one stack.

Usage:
  dcm model up [config] [LLM options]
  dcm model down [config]
  dcm model status [config]
  dcm model logs [config] [docker compose log options]

The LLM starts first and must answer its OpenAI-compatible model endpoint before
the TEI embedding server starts. This preserves every existing LLM
--gpu-memory-utilization value. TEI is bounded by conservative input, batch, and
concurrency limits and listens only on 127.0.0.1:${DCM_EMBEDDING_PORT:-8081}.
Containers attached to the named dcm-model-plane network can instead use
http://dcm-embedding:80/v1 without exposing TEI to the LAN.

Embedding overrides:
  DCM_EMBEDDING_IMAGE                    Pinned GB10/arm64 TEI image
  DCM_EMBEDDING_PORT                     Loopback port (default: 8081)
  DCM_EMBEDDING_MAX_BATCH_TOKENS         Batch token cap (default: 8192)
  DCM_EMBEDDING_MAX_BATCH_REQUESTS       Batch request cap (default: 16)
  DCM_EMBEDDING_MAX_CLIENT_BATCH_SIZE    Per-client batch cap (default: 16)
  DCM_EMBEDDING_MAX_CONCURRENT_REQUESTS  Backpressure cap (default: 32)

Examples:
  dcm model up qwen38-flash-next --vision
  dcm model status qwen38-flash-next
  dcm model logs -f qwen38-flash-next
  dcm model down qwen38-flash-next
EOF
}

get_config_file() {
    local config_name="$1"
    for config in "${CONFIGS[@]}"; do
        IFS=':' read -r name file <<< "$config"
        if [[ "$name" == "$config_name" ]]; then
            echo "$file"
            return 0
        fi
    done
    return 1
}

list_configs() {
    echo "Available configurations:"
    for config in "${CONFIGS[@]}"; do
        IFS=':' read -r name file <<< "$config"
        echo "  - $name ($file)"
    done
}

llm_api_port() {
    case "$1" in
        qwen38-27b|qwen38-flash-next) echo 8001 ;;
        *) echo 8000 ;;
    esac
}

wait_for_openai_model() {
    local label="$1" port="$2" model_alias="$3" timeout="$4"
    local deadline
    [[ "$timeout" =~ ^[0-9]+$ ]] || {
        echo "Error: DCM_MODEL_READY_TIMEOUT must be a non-negative integer" >&2
        return 2
    }
    deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) <= deadline )); do
        if curl -fsS --connect-timeout 1 --max-time 3 \
            "http://127.0.0.1:${port}/health" >/dev/null 2>&1 && \
            curl -fsS --connect-timeout 1 --max-time 3 \
                "http://127.0.0.1:${port}/v1/models" 2>/dev/null | grep -Fq "$model_alias"; then
            echo "$label is ready at http://127.0.0.1:${port}"
            return 0
        fi
        sleep "$MODEL_READY_POLL_SECONDS"
    done
    echo "Error: timed out waiting for $label on http://127.0.0.1:${port}" >&2
    return 1
}

validate_embedding_info() {
    python3 -c '
import json, sys
payload = json.load(sys.stdin)
expected_model, expected_sha = sys.argv[1:3]
if payload.get("model_id") != expected_model:
    raise SystemExit("unexpected TEI model_id")
if payload.get("model_sha") != expected_sha:
    raise SystemExit("unexpected TEI model_sha")
' "$EMBEDDING_MODEL" "$EMBEDDING_MODEL_REVISION"
}

validate_embedding_response() {
    python3 -c '
import json, math, sys
payload = json.load(sys.stdin)
expected_model = sys.argv[1]
reported_model = payload.get("model")
if reported_model is not None and reported_model != expected_model:
    raise SystemExit("unexpected embedding model alias")
data = payload.get("data")
if not isinstance(data, list) or len(data) != 2:
    raise SystemExit("embedding response count mismatch")
if [item.get("index") for item in data] != [0, 1]:
    raise SystemExit("embedding response order mismatch")
for item in data:
    vector = item.get("embedding")
    if not isinstance(vector, list) or len(vector) != 1024:
        raise SystemExit("embedding dimension mismatch")
    if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in vector):
        raise SystemExit("embedding contains non-finite values")
    norm = math.sqrt(sum(float(value) * float(value) for value in vector))
    if not 0.98 <= norm <= 1.02:
        raise SystemExit("embedding is not normalized")
' "$EMBEDDING_MODEL_ALIAS"
}

embedding_contract_ready() {
    local info
    info=$(curl -fsS --connect-timeout 1 --max-time 3 \
        "http://127.0.0.1:${EMBEDDING_PORT}/info") || return 1
    validate_embedding_info <<<"$info" >/dev/null 2>&1 || return 1
    curl -fsS --connect-timeout 1 --max-time 30 \
        -H 'Content-Type: application/json' \
        -X POST \
        -d "{\"model\":\"${EMBEDDING_MODEL_ALIAS}\",\"input\":[\"health probe\",\"상태 확인\"],\"encoding_format\":\"float\"}" \
        "http://127.0.0.1:${EMBEDDING_PORT}/v1/embeddings" \
        | validate_embedding_response >/dev/null 2>&1
}

wait_for_embedding_model() {
    local timeout="$1" deadline
    [[ "$timeout" =~ ^[0-9]+$ ]] || {
        echo "Error: DCM_MODEL_READY_TIMEOUT must be a non-negative integer" >&2
        return 2
    }
    command -v python3 >/dev/null || {
        echo "Error: python3 is required for embedding contract validation" >&2
        return 2
    }
    deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) <= deadline )); do
        if curl -fsS --connect-timeout 1 --max-time 3 \
            "http://127.0.0.1:${EMBEDDING_PORT}/health" >/dev/null 2>&1 && \
            embedding_contract_ready; then
            echo "Embedding model is ready at http://127.0.0.1:${EMBEDDING_PORT}"
            return 0
        fi
        sleep "$MODEL_READY_POLL_SECONDS"
    done
    echo "Error: timed out waiting for the verified embedding contract on http://127.0.0.1:${EMBEDDING_PORT}" >&2
    return 1
}

model_compose() {
    local config_name="$1"
    shift
    local config_file
    config_file=$(get_config_file "$config_name") || {
        echo "Error: Unknown config '$config_name'" >&2
        list_configs >&2
        return 1
    }
    docker compose \
        -f "$SCRIPT_DIR/$config_file" \
        -f "$SCRIPT_DIR/$EMBEDDING_COMPOSE_FILE" \
        "$@"
}

cmd_model_up() {
    local config_name="${1:-default}"
    if [[ $# -gt 0 ]]; then
        shift
    fi
    get_config_file "$config_name" >/dev/null || {
        echo "Error: Unknown config '$config_name'" >&2
        list_configs >&2
        return 1
    }
    [[ -f "$SCRIPT_DIR/$EMBEDDING_COMPOSE_FILE" ]] || {
        echo "Error: embedding Compose file is missing: $SCRIPT_DIR/$EMBEDDING_COMPOSE_FILE" >&2
        return 1
    }

    # vLLM computes its requested memory budget at startup. Starting it before
    # the smaller TEI encoder avoids the embedding process reducing the free
    # memory visible to the primary model.
    cmd_up "$config_name" "$@"
    wait_for_openai_model "LLM" "$(llm_api_port "$config_name")" "local-coder" "$MODEL_READY_TIMEOUT"

    echo "Starting BGE-M3 embedding service after the LLM is ready..."
    if ! model_compose "$config_name" up -d --no-deps embedding; then
        echo "Error: embedding service failed to start; the LLM was left running" >&2
        return 70
    fi
    if ! wait_for_embedding_model "$MODEL_READY_TIMEOUT"; then
        echo "Embedding readiness failed; stopping only the embedding service." >&2
        model_compose "$config_name" stop embedding >/dev/null 2>&1 || true
        return 70
    fi
    echo "Model stack is ready: LLM + $EMBEDDING_MODEL_ALIAS."
}

cmd_model_down() {
    local config_name="${1:-default}"
    [[ $# -le 1 ]] || {
        echo "Error: model down accepts only an optional config name" >&2
        return 2
    }
    echo "Stopping LLM + embedding model stack..."
    model_compose "$config_name" down
    echo "Model stack stopped."
}

cmd_model_status() {
    local config_name="${1:-default}"
    [[ $# -le 1 ]] || {
        echo "Error: model status accepts only an optional config name" >&2
        return 2
    }
    model_compose "$config_name" ps
}

cmd_model_logs() {
    local config_name="default"
    local -a log_args=()
    while [[ $# -gt 0 ]]; do
        if get_config_file "$1" >/dev/null 2>&1; then
            config_name="$1"
        else
            log_args+=("$1")
        fi
        shift
    done
    model_compose "$config_name" logs "${log_args[@]}"
}

cmd_model() {
    local subcommand="${1:-help}"
    [[ $# -eq 0 ]] || shift
    case "$subcommand" in
        up) cmd_model_up "$@" ;;
        down) cmd_model_down "$@" ;;
        status) cmd_model_status "$@" ;;
        logs) cmd_model_logs "$@" ;;
        h|help|-h|--help) show_model_help ;;
        *)
            echo "Error: unknown model command '$subcommand'" >&2
            show_model_help >&2
            return 2
            ;;
    esac
}

cmd_setup() {
    local config_name="${1:-}"
    case "$config_name" in
        qwen38-flash-next)
            "$SCRIPT_DIR/setup-qwen38-flash-next.sh"
            ;;
        "")
            echo "Error: setup requires a config name" >&2
            echo "Available setup target: qwen38-flash-next" >&2
            exit 2
            ;;
        *)
            echo "Error: '$config_name' does not require a setup command" >&2
            exit 2
            ;;
    esac
}

cmd_up() {
    local config_name="${1:-default}"
    if [[ $# -gt 0 ]]; then
        shift
    fi
    local config_file
    config_file=$(get_config_file "$config_name") || {
        echo "Error: Unknown config '$config_name'"
        list_configs
        exit 1
    }

    local model_mode_args="--language-model-only"
    if [[ "$config_name" == "qwen38-flash-next" ]]; then
        model_mode_args=""
    fi
    if [[ "$config_name" == "qwen38-27b" || "$config_name" == "qwen38-flash-next" ]]; then
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --vision)    model_mode_args="" ;;
                --text-only) model_mode_args="--language-model-only" ;;
                *) echo "Error: Unknown $config_name option '$1'" >&2; exit 2 ;;
            esac
            shift
        done
    elif [[ $# -gt 0 ]]; then
        echo "Error: '$config_name' does not support runtime options" >&2
        exit 2
    fi

    if [[ "$config_name" == "qwen38-27b" || "$config_name" == "qwen38-flash-next" ]]; then
        local mode_label="text-only"
        [[ -z "$model_mode_args" ]] && mode_label="vision"
        echo "Starting $config_name service ($mode_label mode)..."
        if [[ "$config_name" == "qwen38-flash-next" ]]; then
            QWEN38_FLASH_MODEL_MODE_ARGS="$model_mode_args" \
                docker compose -f "$SCRIPT_DIR/$config_file" up -d
        else
            QWEN38_MODEL_MODE_ARGS="$model_mode_args" \
                docker compose -f "$SCRIPT_DIR/$config_file" up -d
        fi
    else
        echo "Starting $config_name service..."
        docker compose -f "$SCRIPT_DIR/$config_file" up -d
    fi
    echo "Service started. Use '$0 status $config_name' to check status."
}

cmd_down() {
    local config_name="${1:-default}"
    local config_file
    config_file=$(get_config_file "$config_name") || {
        echo "Error: Unknown config '$config_name'"
        list_configs
        exit 1
    }

    echo "Stopping $config_name service..."
    docker compose -f "$SCRIPT_DIR/$config_file" down
    echo "Service stopped."
}

cmd_status() {
    local config_name="${1:-default}"
    local config_file
    config_file=$(get_config_file "$config_name") || {
        echo "Error: Unknown config '$config_name'"
        list_configs
        exit 1
    }

    echo "Status of $config_name service:"
    docker compose -f "$SCRIPT_DIR/$config_file" ps
}

cmd_restart() {
    local config_name="${1:-default}"
    if [[ $# -gt 0 ]]; then
        shift
    fi
    local config_file
    config_file=$(get_config_file "$config_name") || {
        echo "Error: Unknown config '$config_name'"
        list_configs
        exit 1
    }

    if [[ ( "$config_name" == "qwen38-27b" || "$config_name" == "qwen38-flash-next" ) && $# -gt 0 ]]; then
        local model_mode_args="--language-model-only"
        if [[ "$config_name" == "qwen38-flash-next" ]]; then
            model_mode_args=""
        fi
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --vision)    model_mode_args="" ;;
                --text-only) model_mode_args="--language-model-only" ;;
                *) echo "Error: Unknown $config_name option '$1'" >&2; exit 2 ;;
            esac
            shift
        done
        local mode_label="text-only"
        [[ -z "$model_mode_args" ]] && mode_label="vision"
        echo "Recreating $config_name service ($mode_label mode)..."
        if [[ "$config_name" == "qwen38-flash-next" ]]; then
            QWEN38_FLASH_MODEL_MODE_ARGS="$model_mode_args" \
                docker compose -f "$SCRIPT_DIR/$config_file" up -d --force-recreate
        else
            QWEN38_MODEL_MODE_ARGS="$model_mode_args" \
                docker compose -f "$SCRIPT_DIR/$config_file" up -d --force-recreate
        fi
    elif [[ $# -gt 0 ]]; then
        echo "Error: '$config_name' does not support restart options" >&2
        exit 2
    else
        echo "Restarting $config_name service..."
        docker compose -f "$SCRIPT_DIR/$config_file" restart
    fi
    echo "Service restarted."
}

cmd_logs() {
    local config_name="default"
    local -a log_args=()

    while [[ $# -gt 0 ]]; do
        if get_config_file "$1" >/dev/null; then
            config_name="$1"
        else
            log_args+=("$1")
        fi
        shift
    done

    local config_file
    config_file=$(get_config_file "$config_name") || {
        echo "Error: Unknown config '$config_name'"
        list_configs
        exit 1
    }

    docker compose -f "$SCRIPT_DIR/$config_file" logs "${log_args[@]}"
}

cmd_ps() {
    docker ps \
        --filter "name=vllm-local-coder" \
        --filter "name=dcm-embedding-bge-m3" \
        --format "table CONTAINER\tNAME\tSTATUS\tPORTS"
}

cmd_gpu_job() {
    "$SCRIPT_DIR/gpu-job.sh" "$@"
}

# Main
if [[ $# -lt 1 ]]; then
    show_help
    exit 1
fi

command="$1"
shift

case "$command" in
    setup)
        cmd_setup "$@"
        ;;
    up)
        cmd_up "$@"
        ;;
    down)
        cmd_down "$@"
        ;;
    status)
        cmd_status "$@"
        ;;
    restart)
        cmd_restart "$@"
        ;;
    logs)
        cmd_logs "$@"
        ;;
    ps)
        cmd_ps
        ;;
    model)
        cmd_model "$@"
        ;;
    gpu-job)
        cmd_gpu_job "$@"
        ;;
    h|help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: $command"
        show_help
        exit 1
        ;;
esac
