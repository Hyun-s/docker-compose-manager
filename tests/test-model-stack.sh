#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
EVENTS="$TMP/events"

cat >"$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker' >>"$FAKE_EVENTS"
printf ' <%s>' "$@" >>"$FAKE_EVENTS"
printf '\n' >>"$FAKE_EVENTS"
if [[ "${FAKE_EMBED_UP_FAIL:-0}" == 1 && " $* " == *" up "* && " $* " == *" embedding "* ]]; then
  exit 1
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
  *) exit 1 ;;
esac
EOF

chmod +x "$TMP/bin/docker" "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
export FAKE_EVENTS="$EVENTS"
export DCM_MODEL_READY_TIMEOUT=1
export DCM_MODEL_READY_POLL_SECONDS=0

"$ROOT/docker-compose-manager.sh" h >"$TMP/help"
grep -q 'model    Manage the LLM + BGE-M3 embedding stack' "$TMP/help"
"$ROOT/docker-compose-manager.sh" model h >"$TMP/model-help"
grep -q 'dcm model up' "$TMP/model-help"
grep -q '127.0.0.1:8081' "$TMP/model-help"

: >"$EVENTS"
"$ROOT/docker-compose-manager.sh" model up qwen38-27b --vision >"$TMP/up-output"
grep -Fq 'docker <compose> <-f> <'"$ROOT"'/docker-compose.qwen38-27b.yml> <up> <-d>' "$EVENTS"
grep -Fq 'curl <http://127.0.0.1:8001/v1/models>' "$EVENTS"
grep -Fq 'docker <compose> <-f> <'"$ROOT"'/docker-compose.qwen38-27b.yml> <-f> <'"$ROOT"'/docker-compose.embedding.yml> <up> <-d> <--no-deps> <embedding>' "$EVENTS"
grep -Fq 'curl <http://127.0.0.1:8081/info>' "$EVENTS"
grep -Fq 'curl <http://127.0.0.1:8081/v1/embeddings>' "$EVENTS"
grep -q 'Model stack is ready' "$TMP/up-output"

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
  echo 'embedding start failure unexpectedly stopped the LLM or issued a cleanup stop' >&2
  exit 1
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
  echo 'embedding contract failure unexpectedly stopped the LLM stack' >&2
  exit 1
fi

: >"$EVENTS"
"$ROOT/docker-compose-manager.sh" model status qwen38-27b
grep -Fq '<'"$ROOT"'/docker-compose.embedding.yml> <ps>' "$EVENTS"

: >"$EVENTS"
"$ROOT/docker-compose-manager.sh" model logs -n 25 qwen38-27b
grep -Fq '<'"$ROOT"'/docker-compose.embedding.yml> <logs> <-n> <25>' "$EVENTS"

: >"$EVENTS"
"$ROOT/docker-compose-manager.sh" model down qwen38-27b
grep -Fq '<'"$ROOT"'/docker-compose.embedding.yml> <down>' "$EVENTS"

: >"$EVENTS"
"$ROOT/docker-compose-manager.sh" up qwen38-27b --text-only
grep -Fq '<'"$ROOT"'/docker-compose.qwen38-27b.yml> <up> <-d>' "$EVENTS"
if grep -q 'docker-compose.embedding.yml' "$EVENTS"; then
  echo 'legacy dcm up unexpectedly touched the embedding service' >&2
  exit 1
fi

echo "model stack tests passed"
