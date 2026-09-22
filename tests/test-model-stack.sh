#!/usr/bin/env bash
# Behaviour lock for `dcm model` and `dcm encoders`.
#
# The property that matters most here is NOT startup order, it is isolation:
# the interactive agent session is served by vllm-local-coder, so no encoder
# command may ever be able to converge the LLM Compose project. These tests use
# a fake `docker`/`curl` and assert the exact command shapes, including the
# pinned `-p <encoders project>` on every encoder invocation.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
EVENTS="$TMP/events"
LLM_FILE="$ROOT/docker-compose.qwen38-27b.yml"
ENC_FILE="$ROOT/docker-compose.embedding.yml"

cat >"$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker' >>"$FAKE_EVENTS"
printf ' <%s>' "$@" >>"$FAKE_EVENTS"
printf '\n' >>"$FAKE_EVENTS"
if [[ "${FAKE_EMBED_UP_FAIL:-0}" == 1 && " $* " == *" up "* && " $* " == *" embedding "* ]]; then
  exit 1
fi
# TEI prints the backend it actually got; candle prints "Using CPU instead" when
# it cannot create a CUDA context. Tests pick which world they live in.
if [[ "${1:-}" == logs ]]; then
  case "${FAKE_ENCODER_BACKEND:-unknown}" in
    cpu) printf '%s\n' 'Using CPU instead' ;;
    gpu) printf '%s\n' 'Starting FlashBert model on Cuda(CudaDevice(DeviceId(1)))' ;;
  esac
  exit 0
fi
EOF

cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
printf 'curl <%s>\n' "$url" >>"$FAKE_EVENTS"
case "$url" in
  */health) exit 0 ;;
  *:8000/v1/models|*:8001/v1/models) printf '%s\n' '{"data":[{"id":"local-coder"}]}' ;;
  *:8081/info)
    if [[ "${FAKE_BAD_EMBEDDING_CONTRACT:-0}" == 1 ]]; then
      printf '%s\n' '{"model_id":"BAAI/bge-m3","model_sha":"unexpected"}'
    else
      printf '%s\n' '{"model_id":"BAAI/bge-m3","model_sha":"5617a9f61b028005a4858fdac845db406aefb181"}'
    fi
    ;;
  *:8081/v1/embeddings)
    python3 - <<'PY'
import json
vector = [1.0] + [0.0] * 1023
print(json.dumps({
    "object": "list",
    "model": "bge-m3",
    "data": [
        {"object": "embedding", "index": 0, "embedding": vector},
        {"object": "embedding", "index": 1, "embedding": vector},
    ],
}))
PY
    ;;
  *:8082/info)
    if [[ "${FAKE_BAD_RERANKER_CONTRACT:-0}" == 1 ]]; then
      printf '%s\n' '{"model_id":"BAAI/bge-reranker-v2-m3","model_sha":"unexpected"}'
    else
      printf '%s\n' '{"model_id":"BAAI/bge-reranker-v2-m3","model_sha":"953dc6f6f85a1b2dbfca4c34a2796e7dde08d41e","model_type":{"reranker":{}},"max_input_length":4096}'
    fi
    ;;
  *:8082/rerank|*:8082/v1/rerank)
    # TEI 1.9 answers with a bare array sorted by score descending.
    # FAKE_BAD_RERANKER_SHAPE emulates the vLLM {results:[...]} body, which the
    # dcm validator must reject rather than quietly accept.
    if [[ "${FAKE_BAD_RERANKER_SHAPE:-0}" == 1 ]]; then
      printf '%s\n' '{"results":[{"index":0,"relevance_score":0.9},{"index":1,"relevance_score":0.5},{"index":2,"relevance_score":0.1}]}'
    elif [[ "${FAKE_BAD_RERANKER_ORDER:-0}" == 1 ]]; then
      printf '%s\n' '[{"index":0,"score":0.1},{"index":1,"score":0.9},{"index":2,"score":0.5}]'
    else
      printf '%s\n' '[{"index":0,"score":0.9},{"index":1,"score":0.5},{"index":2,"score":0.1}]'
    fi
    ;;
  *) exit 1 ;;
esac
EOF

chmod +x "$TMP/bin/docker" "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
export FAKE_EVENTS="$EVENTS"
export DCM_MODEL_READY_TIMEOUT=1
export DCM_MODEL_READY_POLL_SECONDS=0
export DCM_SKIP_LOAD_PROBE=1

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------- help surface
"$ROOT/docker-compose-manager.sh" h >"$TMP/help"
grep -q 'model    Manage the full LLM + encoder stack' "$TMP/help"
grep -q 'encoders Manage only the always-on TEI encoders' "$TMP/help"
"$ROOT/docker-compose-manager.sh" model h >"$TMP/model-help"
grep -q 'dcm model up' "$TMP/model-help"
grep -q '127.0.0.1:8081' "$TMP/model-help"
"$ROOT/docker-compose-manager.sh" encoders h >"$TMP/enc-help"
grep -q 'dcm encoders up' "$TMP/enc-help"
grep -q 'dcm encoders validate' "$TMP/enc-help"
grep -q 'DCM_REQUIRE_GPU' "$TMP/model-help"
grep -q 'DCM_REQUIRE_GPU' "$TMP/enc-help"

# The help blocks are expanding heredocs, so prose backticks there become command
# substitutions: reading help must never run 'dcm model up' or 'dcm encoders'.
: >"$EVENTS"
"$ROOT/docker-compose-manager.sh" h >/dev/null
"$ROOT/docker-compose-manager.sh" model h >/dev/null
"$ROOT/docker-compose-manager.sh" encoders h >/dev/null
[[ -s "$EVENTS" ]] && fail 'printing help executed a docker command'
for help_file in help model-help enc-help; do
  grep -q '`' "$TMP/$help_file" \
    && fail "help text still contains a backtick command substitution: $help_file"
done
grep -q 'dcm-model-plane' "$TMP/enc-help"

# ------------------------------------------------------- model up: LLM, then
: >"$EVENTS"
"$ROOT/docker-compose-manager.sh" model up qwen38-27b --vision >"$TMP/up-output"
grep -Fq 'docker <compose> <-f> <'"$LLM_FILE"'> <up> <-d>' "$EVENTS"
grep -Fq 'curl <http://127.0.0.1:8001/v1/models>' "$EVENTS"
grep -Fq 'docker <compose> <-p> <dcm-model-plane> <-f> <'"$ENC_FILE"'> <up> <-d> <--no-deps> <embedding> <reranker>' "$EVENTS"
grep -Fq 'curl <http://127.0.0.1:8081/info>' "$EVENTS"
grep -Fq 'curl <http://127.0.0.1:8081/v1/embeddings>' "$EVENTS"
grep -Fq 'curl <http://127.0.0.1:8082/info>' "$EVENTS"
grep -Fq 'curl <http://127.0.0.1:8082/rerank>' "$EVENTS"
grep -q 'Model stack is ready' "$TMP/up-output"
grep -q 'MemAvailable' "$TMP/up-output" || fail "status must report memory headroom"

# LLM must come up first so --gpu-memory-utilization keeps the same budget.
llm_line=$(grep -nF "<$LLM_FILE> <up> <-d>" "$EVENTS" | head -1 | cut -d: -f1)
enc_line=$(grep -nF "<$ENC_FILE> <up> <-d>" "$EVENTS" | head -1 | cut -d: -f1)
[[ "$llm_line" -lt "$enc_line" ]] || fail "encoders started before the LLM was ready"

# ------------------------------------- every encoder compose call pins -p (ISO)
while IFS= read -r line; do
  case "$line" in *"$ENC_FILE"*) grep -Fq '<-p> <dcm-model-plane>' <<<"$line" \
        || fail "encoder compose call is not project-pinned: $line";; esac
done <"$EVENTS"

# ---------------------------------------------- encoder failure must not touch
: >"$EVENTS"
export FAKE_EMBED_UP_FAIL=1
set +e
"$ROOT/docker-compose-manager.sh" model up qwen38-27b --vision >"$TMP/embed-up-failure-output" 2>&1
rc=$?
set -e
unset FAKE_EMBED_UP_FAIL
[[ "$rc" -eq 70 ]]
grep -q 'LLM was left running' "$TMP/embed-up-failure-output"
if grep -Eq '<down>|<stop> <embedding>' "$EVENTS"; then
  fail 'embedding start failure unexpectedly stopped the LLM or issued a cleanup stop'
fi

: >"$EVENTS"
export FAKE_BAD_EMBEDDING_CONTRACT=1 DCM_MODEL_READY_TIMEOUT=0
set +e
"$ROOT/docker-compose-manager.sh" model up qwen38-27b --vision >"$TMP/embed-contract-failure-output" 2>&1
rc=$?
set -e
unset FAKE_BAD_EMBEDDING_CONTRACT
export DCM_MODEL_READY_TIMEOUT=1
[[ "$rc" -eq 70 ]]
grep -q 'stopping only the embedding service' "$TMP/embed-contract-failure-output"
grep -Fq '<stop> <embedding>' "$EVENTS"
if grep -q '<down>' "$EVENTS"; then
  fail 'embedding contract failure unexpectedly stopped the LLM stack'
fi

: >"$EVENTS"
export FAKE_BAD_RERANKER_CONTRACT=1 DCM_MODEL_READY_TIMEOUT=0
set +e
"$ROOT/docker-compose-manager.sh" model up qwen38-27b --vision >"$TMP/rerank-contract-failure-output" 2>&1
rc=$?
set -e
unset FAKE_BAD_RERANKER_CONTRACT
export DCM_MODEL_READY_TIMEOUT=1
[[ "$rc" -eq 70 ]]
grep -q 'stopping only the reranker service' "$TMP/rerank-contract-failure-output"
grep -Fq '<stop> <reranker>' "$EVENTS"
grep -Fq '<stop> <embedding>' "$EVENTS" && fail 'reranker failure stopped the healthy embedding service'
if grep -q '<down>' "$EVENTS"; then
  fail 'reranker contract failure unexpectedly stopped the LLM stack'
fi

# --------------------------------- /rerank body shape must be TEI bare-array
: >"$EVENTS"
export FAKE_BAD_RERANKER_SHAPE=1 DCM_MODEL_READY_TIMEOUT=0
set +e
"$ROOT/docker-compose-manager.sh" model up qwen38-27b --vision >"$TMP/rerank-shape-output" 2>&1
rc=$?
set -e
unset FAKE_BAD_RERANKER_SHAPE
export DCM_MODEL_READY_TIMEOUT=1
[[ "$rc" -eq 70 ]] || fail 'the vLLM {results:[...]} rerank body must not satisfy the TEI contract'

: >"$EVENTS"
export FAKE_BAD_RERANKER_ORDER=1 DCM_MODEL_READY_TIMEOUT=0
set +e
"$ROOT/docker-compose-manager.sh" model up qwen38-27b --vision >"$TMP/rerank-order-output" 2>&1
rc=$?
set -e
unset FAKE_BAD_RERANKER_ORDER
export DCM_MODEL_READY_TIMEOUT=1
[[ "$rc" -eq 70 ]] || fail 'unsorted rerank scores must not satisfy the contract'

# --------------------------------------------------- model status/logs/down
: >"$EVENTS"
"$ROOT/docker-compose-manager.sh" model status qwen38-27b
grep -Fq '<'"$ENC_FILE"'> <ps>' "$EVENTS"

: >"$EVENTS"
"$ROOT/docker-compose-manager.sh" model logs -n 25 qwen38-27b
grep -Fq '<'"$ENC_FILE"'> <logs> <-n> <25>' "$EVENTS"

: >"$EVENTS"
"$ROOT/docker-compose-manager.sh" model down qwen38-27b
grep -Fq '<-p> <dcm-model-plane> <-f> <'"$ENC_FILE"'> <down>' "$EVENTS"
grep -Fq '<'"$LLM_FILE"'> <down>' "$EVENTS"

# --------------------------------------- encoders alone: the LLM is untouchable
for sub in up down status validate probe; do
  : >"$EVENTS"
  case "$sub" in
    up) FAKE_EMBED_UP_FAIL=1 "$ROOT/docker-compose-manager.sh" encoders up >"$TMP/enc-$sub" 2>&1 || true ;;
    *) "$ROOT/docker-compose-manager.sh" encoders "$sub" >"$TMP/enc-$sub" 2>&1 || true ;;
  esac
  if grep -q "docker-compose.qwen" "$EVENTS"; then
    fail "dcm encoders $sub referenced an LLM Compose file"
  fi
done

: >"$EVENTS"
"$ROOT/docker-compose-manager.sh" encoders down
grep -Fq '<-p> <dcm-model-plane> <-f> <'"$ENC_FILE"'> <down> <--remove-orphans>' "$EVENTS"
if grep -q "docker-compose.qwen" "$EVENTS"; then
  fail 'dcm encoders down referenced an LLM Compose file'
fi

: >"$EVENTS"
"$ROOT/docker-compose-manager.sh" encoders validate >"$TMP/enc-validate"
grep -q 'OK: /info attestation + 2 inputs' "$TMP/enc-validate"
grep -q 'OK: /info attestation + /rerank bare-array' "$TMP/enc-validate"
grep -q 'DCM_SKIP_LOAD_PROBE=1' "$TMP/enc-validate"

: >"$EVENTS"
export FAKE_BAD_RERANKER_CONTRACT=1
set +e
"$ROOT/docker-compose-manager.sh" encoders validate >"$TMP/enc-validate-bad" 2>&1
rc=$?
set -e
unset FAKE_BAD_RERANKER_CONTRACT
[[ "$rc" -ne 0 ]] || fail 'encoders validate must fail on an unattested reranker'

# --------------------------- max_concurrent_requests >= max_client_batch_size
# A client batch larger than the permit pool is a guaranteed 429 at query time,
# so dcm must refuse to start that configuration rather than fail later.
: >"$EVENTS"
set +e
DCM_RERANKER_MAX_CONCURRENT_REQUESTS=16 DCM_RERANKER_MAX_CLIENT_BATCH_SIZE=64 \
  "$ROOT/docker-compose-manager.sh" encoders up >"$TMP/permit-guard" 2>&1
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail 'an unsatisfiable permit budget must be refused with exit 2'
grep -q 'guaranteed 429' "$TMP/permit-guard"
if grep -qF "<up>" "$EVENTS"; then
  fail 'the permit-budget guard started containers instead of refusing'
fi

# ------------------------------------------- GPU is the default, not a request
# A CPU-served BGE is exactly the slow-answer bug this plane exists to fix, so an
# unresolved fallback must fail the command instead of printing a healthy line.
: >"$EVENTS"
set +e
FAKE_ENCODER_BACKEND=cpu DCM_GPU_START_ATTEMPTS=1 \
  "$ROOT/docker-compose-manager.sh" encoders up >"$TMP/backend-cpu" 2>&1
rc=$?
set -e
[[ "$rc" -eq 70 ]] || fail "a CPU-served encoder must exit 70, got $rc"
grep -q 'GPU is required' "$TMP/backend-cpu"
grep -q 'CPU FALLBACK' "$TMP/backend-cpu"
grep -q 'fail-open' "$TMP/backend-cpu"
if grep -q 'Encoders are ready' "$TMP/backend-cpu"; then
  fail 'a CPU fallback printed "Encoders are ready"'
fi
# The gate must retry on GPU before giving up, not quit on the first CPU landing.
grep -Fq '<up> <-d> <--force-recreate> <embedding> <reranker>' "$EVENTS" \
  || fail 'the GPU gate never recreated the CPU-served encoders'
if grep -qF "<$LLM_FILE>" "$EVENTS"; then
  fail 'the GPU gate referenced an LLM Compose file'
fi

: >"$EVENTS"
FAKE_ENCODER_BACKEND=gpu DCM_GPU_START_ATTEMPTS=1 \
  "$ROOT/docker-compose-manager.sh" encoders up >"$TMP/backend-gpu"
grep -q 'Encoders are ready on GPU' "$TMP/backend-gpu"
if grep -q 'CPU FALLBACK' "$TMP/backend-gpu"; then
  fail 'a CUDA-attested encoder was reported as a CPU fallback'
fi

# A missing backend line is unattested, not proof of GPU.
: >"$EVENTS"
"$ROOT/docker-compose-manager.sh" encoders up >"$TMP/backend-unknown" 2>&1
grep -q 'backend is unattested' "$TMP/backend-unknown"
if grep -q 'ready on GPU' "$TMP/backend-unknown"; then
  fail 'dcm claimed a GPU backend it never saw in the logs'
fi

# DCM_REQUIRE_GPU=0 is the only way to accept the slow path, and it says so.
: >"$EVENTS"
set +e
FAKE_ENCODER_BACKEND=cpu DCM_REQUIRE_GPU=0 DCM_GPU_START_ATTEMPTS=1 \
  "$ROOT/docker-compose-manager.sh" encoders up >"$TMP/gpu-optout" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "DCM_REQUIRE_GPU=0 must keep a deliberately slow encoder up, got $rc"
grep -q 'DCM_REQUIRE_GPU=0' "$TMP/gpu-optout"
grep -q 'Encoders are ready on CPU' "$TMP/gpu-optout"

# ------------------------------- model up is one command for both GPU models
# It must fail loudly if the encoders it also started land on CPU, and it must
# have tried the LLM and the encoders in that same single invocation.
: >"$EVENTS"
set +e
FAKE_ENCODER_BACKEND=cpu DCM_GPU_START_ATTEMPTS=1 \
  "$ROOT/docker-compose-manager.sh" model up qwen38-27b --vision >"$TMP/model-up-cpu" 2>&1
rc=$?
set -e
[[ "$rc" -eq 70 ]] || fail "model up must fail when it cannot serve both models on GPU, got $rc"
grep -q 'GPU is required' "$TMP/model-up-cpu"
grep -Fq '<'"$LLM_FILE"'> <up> <-d>' "$EVENTS"
grep -Fq '<-p> <dcm-model-plane> <-f> <'"$ENC_FILE"'> <up> <-d> <--no-deps> <embedding> <reranker>' "$EVENTS"
if grep -q 'Model stack is ready' "$TMP/model-up-cpu"; then
  fail 'model up reported a ready stack while an encoder was CPU-served'
fi

# ------------------------------------------- legacy single-service commands
: >"$EVENTS"
"$ROOT/docker-compose-manager.sh" up qwen38-27b --text-only
grep -Fq '<'"$LLM_FILE"'> <up> <-d>' "$EVENTS"
if grep -q 'docker-compose.embedding.yml' "$EVENTS"; then
  fail 'legacy dcm up unexpectedly touched the embedding service'
fi

echo "model stack tests passed"
