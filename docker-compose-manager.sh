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
RERANKER_MODEL="${DCM_RERANKER_MODEL:-BAAI/bge-reranker-v2-m3}"
RERANKER_MODEL_REVISION="${DCM_RERANKER_MODEL_REVISION:-953dc6f6f85a1b2dbfca4c34a2796e7dde08d41e}"
RERANKER_MODEL_ALIAS="${DCM_RERANKER_MODEL_ALIAS:-bge-reranker-v2-m3}"
RERANKER_PORT="${DCM_RERANKER_PORT:-8082}"
# The encoder Compose project MUST stay separate from the LLM Compose project.
# All three containers currently share project "local-claude-code", so a
# `docker compose -f docker-compose.embedding.yml down` while they share a
# project stops vllm-local-coder too - which kills the Codex session that is
# served by that very container. Every encoder command therefore pins -p.
ENCODERS_PROJECT="${DCM_ENCODERS_PROJECT:-dcm-model-plane}"
ENCODER_CONTAINERS=(dcm-embedding-bge-m3 dcm-reranker-bge-v2-m3)
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
  model    Manage the full LLM + encoder stack (up/down/status/logs) - restarts the LLM too
  encoders Manage only the always-on TEI encoders (BGE-M3 + BGE-reranker-v2-m3)
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
  $0 encoders status            # encoders only; never touches the LLM container
  $0 encoders validate          # live /info + /v1/embeddings + /rerank contract probe
  $0 gpu-job run -- ./train_lora.sh
  $0 gpu-job status
  $0 gpu-job recover       # Restore vLLM after an interrupted/killed wrapper

Note: When using alias 'dcm', replace '$0' with 'dcm' in examples.
EOF
}

show_model_help() {
    cat << EOF
Manage the local LLM and both always-on TEI encoders (BGE-M3 embedding +
BGE-reranker-v2-m3) as one stack. Use `dcm encoders` instead whenever you do NOT
intend to restart the LLM: this command's `down` stops the LLM too, and that is
the container serving the interactive agent session.

Usage:
  dcm model up [config] [LLM options]
  dcm model down [config]
  dcm model status [config]      # includes CUDA-vs-CPU backend + MemAvailable
  dcm encoders status            # encoders only; never converges the LLM
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

# Converge ONLY the TEI encoders. This never loads an LLM Compose file and
# always pins its own project name, so vllm-local-coder can never be selected
# as a service to stop, restart, or remove as an "orphan".
encoders_compose() {
    [[ -f "$SCRIPT_DIR/$EMBEDDING_COMPOSE_FILE" ]] || {
        echo "Error: encoder Compose file is missing: $SCRIPT_DIR/$EMBEDDING_COMPOSE_FILE" >&2
        return 1
    }
    docker compose -p "$ENCODERS_PROJECT" \
        -f "$SCRIPT_DIR/$EMBEDDING_COMPOSE_FILE" \
        "$@"
}

validate_rerank_response() {
    python3 -c '
import json, math, sys
payload = json.load(sys.stdin)
expected_count = int(sys.argv[1])
# TEI 1.9 answers POST /rerank with a BARE ARRAY sorted by score descending and
# returns 404 for /v1/rerank, so do not accept the {results:[...]} vLLM shape
# here; the Maple Chat client handles that shape separately.
if not isinstance(payload, list):
    raise SystemExit("rerank response is not a bare array")
if len(payload) != expected_count:
    raise SystemExit("rerank response count mismatch")
indices = [item.get("index") for item in payload]
if sorted(indices) != list(range(expected_count)):
    raise SystemExit("rerank response index set mismatch")
scores = [item.get("score") for item in payload]
if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in scores):
    raise SystemExit("rerank contains non-finite scores")
if scores != sorted(scores, reverse=True):
    raise SystemExit("rerank scores are not sorted descending")
' "$1"
}

reranker_contract_ready() {
    local info
    info=$(curl -fsS --connect-timeout 1 --max-time 3 \
        "http://127.0.0.1:${RERANKER_PORT}/info") || return 1
    python3 -c '
import json, sys
payload = json.load(sys.stdin)
expected_model, expected_sha = sys.argv[1:3]
if payload.get("model_id") != expected_model:
    raise SystemExit("unexpected TEI reranker model_id")
if payload.get("model_sha") != expected_sha:
    raise SystemExit("unexpected TEI reranker model_sha")
' "$RERANKER_MODEL" "$RERANKER_MODEL_REVISION" <<<"$info" >/dev/null 2>&1 || return 1
    curl -fsS --connect-timeout 1 --max-time 60 \
        -H 'Content-Type: application/json' \
        -X POST \
        -d "{\"model\":\"${RERANKER_MODEL_ALIAS}\",\"query\":\"경험치 효율\",\"texts\":[\"경험치 효율이 좋은 던전 배치\",\"상점 물품 가격표\",\"채널 이동 안내\"]}" \
        "http://127.0.0.1:${RERANKER_PORT}/rerank" \
        | validate_rerank_response 3 >/dev/null 2>&1
}

wait_for_reranker_model() {
    local timeout="$1" deadline
    [[ "$timeout" =~ ^[0-9]+$ ]] || {
        echo "Error: DCM_MODEL_READY_TIMEOUT must be a non-negative integer" >&2
        return 2
    }
    command -v python3 >/dev/null || {
        echo "Error: python3 is required for reranker contract validation" >&2
        return 2
    }
    deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) <= deadline )); do
        if curl -fsS --connect-timeout 1 --max-time 3 \
            "http://127.0.0.1:${RERANKER_PORT}/health" >/dev/null 2>&1 && \
            reranker_contract_ready; then
            echo "Reranker model is ready at http://127.0.0.1:${RERANKER_PORT}"
            return 0
        fi
        sleep "$MODEL_READY_POLL_SECONDS"
    done
    echo "Error: timed out waiting for the verified reranker contract on http://127.0.0.1:${RERANKER_PORT}" >&2
    return 1
}

# TEI silently falls back to CPU when it cannot get a CUDA context on the GB10
# unified-memory device. Latency stays tolerable for a single query but the
# always-on premise is defeated, so surface the actual backend and the host
# memory headroom instead of pretending the model is on the GPU.
report_encoder_backends() {
    local container backend failed=0
    for container in "${ENCODER_CONTAINERS[@]}"; do
        docker inspect "$container" >/dev/null 2>&1 || { echo "  $container: absent"; continue; }
        backend=$(docker logs "$container" 2>&1 \
            | grep -Eo 'Starting [A-Za-z]+ model on (Cuda\([A-Za-z0-9()]*\)|Cpu)|Using CPU instead' \
            | tail -1 || true)
        case "$backend" in
            *Cuda*) echo "  $container: GPU (${backend})" ;;
            *Cpu*|*CPU*) echo "  $container: CPU FALLBACK (${backend}) - model is NOT on the GPU" >&2; failed=1 ;;
            *) echo "  $container: backend unknown (still loading?)" ;;
        esac
    done
    local avail_gib
    avail_gib=$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo)
    echo "  host MemAvailable: ${avail_gib} GiB"
    if (( $(awk -v v="$avail_gib" 'BEGIN{print (v<8)?1:0}') )); then
        echo "  Warning: MemAvailable below 8 GiB; TEI may refuse CUDA and fall back to CPU." >&2
        failed=1
    fi
    return "$failed"
}

start_encoders() {
    echo "Starting TEI encoders (project: $ENCODERS_PROJECT)..."
    if ! encoders_compose up -d --no-deps embedding reranker; then
        echo "Error: encoder services failed to start; the LLM was left running" >&2
        return 70
    fi
    if ! wait_for_embedding_model "$MODEL_READY_TIMEOUT"; then
        echo "Embedding readiness failed; stopping only the embedding service." >&2
        encoders_compose stop embedding >/dev/null 2>&1 || true
        return 70
    fi
    if ! wait_for_reranker_model "$MODEL_READY_TIMEOUT"; then
        echo "Reranker readiness failed; stopping only the reranker service." >&2
        encoders_compose stop reranker >/dev/null 2>&1 || true
        return 70
    fi
    report_encoder_backends || true
    echo "Encoders are ready: $EMBEDDING_MODEL_ALIAS + $RERANKER_MODEL_ALIAS."
}

stop_encoders() {
    echo "Stopping TEI encoders (project: $ENCODERS_PROJECT; the LLM is untouched)..."
    encoders_compose down --remove-orphans
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

    # vLLM computes its requested memory budget at startup. Starting it before
    # the smaller TEI encoders avoids the encoder processes reducing the free
    # memory visible to the primary model, so every existing
    # --gpu-memory-utilization value stays unchanged.
    cmd_up "$config_name" "$@"
    wait_for_openai_model "LLM" "$(llm_api_port "$config_name")" "local-coder" "$MODEL_READY_TIMEOUT"

    start_encoders || return 70
    echo "Model stack is ready: LLM + $EMBEDDING_MODEL_ALIAS + $RERANKER_MODEL_ALIAS."
}

cmd_model_down() {
    local config_name="${1:-default}"
    [[ $# -le 1 ]] || {
        echo "Error: model down accepts only an optional config name" >&2
        return 2
    }
    echo "Stopping LLM + encoder model stack..."
    encoders_compose down >/dev/null 2>&1 || true
    cmd_down "$config_name"
    echo "Model stack stopped."
}

cmd_model_status() {
    local config_name="${1:-default}"
    [[ $# -le 1 ]] || {
        echo "Error: model status accepts only an optional config name" >&2
        return 2
    }
    local config_file
    config_file=$(get_config_file "$config_name") || {
        echo "Error: Unknown config '$config_name'" >&2
        return 1
    }
    echo "LLM service ($config_name):"
    docker compose -f "$SCRIPT_DIR/$config_file" ps
    echo "Encoder services (project: $ENCODERS_PROJECT):"
    encoders_compose ps
    echo "Encoder compute backend / memory headroom:"
    report_encoder_backends
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
    local config_file
    config_file=$(get_config_file "$config_name") || {
        echo "Error: Unknown config '$config_name'" >&2
        return 1
    }
    docker compose -f "$SCRIPT_DIR/$config_file" logs "${log_args[@]}"
    encoders_compose logs "${log_args[@]}"
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

show_encoders_help() {
    cat << EOF
Manage ONLY the always-on TEI encoders (BGE-M3 embedding + BGE-reranker-v2-m3).

Usage:
  dcm encoders up        Start embedding + reranker (contract-validated, no LLM touched)
  dcm encoders down      Stop them (Compose project $ENCODERS_PROJECT only)
  dcm encoders restart   Recreate them
  dcm encoders status    ps + CUDA/CPU backend + MemAvailable headroom
  dcm encoders logs      docker compose logs for both encoders
  dcm encoders validate  Probe the live /info, /v1/embeddings and /rerank contracts
  dcm encoders probe     Replay Maple Chat's real 30 x ~600 token rerank shape

Safety contract: every command here pins Compose project "$ENCODERS_PROJECT" and
never loads an LLM Compose file, so vllm-local-coder can never be converged -
not as a service and not as an "orphan". Use dcm model up|down only when you
intend to restart the LLM as well; that also restarts the service this Codex
session is served by.

Reranker sizing (measured on this box):
  POST /rerank with 30 docs x ~600 tokens is Maple Chat's real rerank shape
  (rerank_limit=30, chunk target 550 / max 700 tokens) and needs about 18k
  tokens in one request. With --max-batch-tokens 4096 TEI answers
  429 {"error":"Model is overloaded"}, so the default is 20480.
  Embeddings cap one request at --max-client-batch-size 32.

Overrides:
  DCM_RERANKER_IMAGE / DCM_RERANKER_PORT / DCM_RERANKER_MODEL / _MODEL_REVISION
  DCM_RERANKER_MAX_BATCH_TOKENS (default 20480) / _MAX_BATCH_REQUESTS (8)
  DCM_RERANKER_MAX_CLIENT_BATCH_SIZE (64) / _MAX_CONCURRENT_REQUESTS (16)
  DCM_EMBEDDING_* as before, DCM_ENCODERS_PROJECT to rename the project.

Examples:
  dcm encoders status
  dcm encoders validate
  dcm encoders up
EOF
}

cmd_encoders_probe() {
    local rc=0
    echo "Rerank load probe (30 x ~600 tokens, the Maple Chat shape):"
    python3 - "$RERANKER_PORT" <<'PYEOF' || rc=1
import json, sys, urllib.request, urllib.error
port = sys.argv[1]
unit = (" Maple 스토리윕의 던전 배치와 몬스터 스폰 주기는 경험치 효율에 직접적인 "
        "영향을 주며, 파티원 수와 채널 분산에 따라 보상 배율이 달라진다. ")
doc = (unit * 4)[:2400]
body = json.dumps({"model": "bge-reranker-v2-m3",
                   "query": "경험치 효율이 가장 좋은 던전 배치는?",
                   "texts": [doc] * 30}).encode()
req = urllib.request.Request(f"http://127.0.0.1:{port}/rerank", data=body,
                             headers={"Content-Type": "application/json"}, method="POST")
try:
    with urllib.request.urlopen(req, timeout=180) as r:
        scores = json.loads(r.read())
    print(f"  OK: 30 x ~600 tokens scored, {len(scores)} results")
except urllib.error.HTTPError as exc:
    raise SystemExit(f"FAILED: HTTP {exc.code} {exc.read()[:120].decode('utf8', 'replace')}")
PYEOF
    return "$rc"
}

cmd_encoders_validate() {
    local rc=0
    echo "Embedding contract (http://127.0.0.1:${EMBEDDING_PORT}):"
    embedding_contract_ready && echo "  OK: /info attestation + 2 inputs -> 1024-dim normalized vectors" || { echo "  FAILED" >&2; rc=1; }
    echo "Reranker contract (http://127.0.0.1:${RERANKER_PORT}):"
    reranker_contract_ready && echo "  OK: /info attestation + /rerank bare-array 3 scores sorted DESC" || { echo "  FAILED" >&2; rc=1; }
    if [[ "${DCM_SKIP_LOAD_PROBE:-0}" == 1 ]]; then
        echo "Rerank load probe skipped (DCM_SKIP_LOAD_PROBE=1)."
        return "$rc"
    fi
    cmd_encoders_probe || rc=1
    return "$rc"
}

cmd_encoders() {
    local subcommand="${1:-help}"
    [[ $# -eq 0 ]] || shift
    case "$subcommand" in
        up) start_encoders ;;
        down) stop_encoders ;;
        restart) encoders_compose up -d --force-recreate embedding reranker && start_encoders ;;
        status) encoders_compose ps; report_encoder_backends ;;
        logs) encoders_compose logs "$@" ;;
        validate) cmd_encoders_validate ;;
        probe) cmd_encoders_probe ;;
        h|help|-h|--help) show_encoders_help ;;
        *)
            echo "Error: unknown encoders command '$subcommand'" >&2
            show_encoders_help >&2
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
    encoders)
        cmd_encoders "$@"
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
