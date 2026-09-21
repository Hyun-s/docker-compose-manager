#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'python3 - "$TMP" <<'"'"'PY'"'"'
import shutil, sys
shutil.rmtree(sys.argv[1], ignore_errors=True)
PY' EXIT

mkdir -p "$TMP/bin" "$TMP/state"
EVENTS="$TMP/events"
RUNNING="$TMP/running"
EMBED_RUNNING="$TMP/embed-running"
printf 'true\n' >"$RUNNING"
printf 'false\n' >"$EMBED_RUNNING"

cat >"$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
name="${*: -1}"
if [[ "$name" == "dcm-embedding-bge-m3" && "${FAKE_EMBED_EXISTS:-0}" != 1 ]]; then
  exit 1
fi
running_file="$FAKE_RUNNING"
[[ "$name" == "dcm-embedding-bge-m3" ]] && running_file="$FAKE_EMBED_RUNNING"
case "$1" in
  inspect)
    if [[ "${2:-}" == "-f" ]]; then
      case "$3" in
        *State.Running*) cat "$running_file" ;;
        *Id*) echo "fake-container-id:$name" ;;
        *) echo unknown ;;
      esac
    fi
    ;;
  stop)
    if [[ "${FAKE_STOP_FAIL:-0}" == 1 ]]; then
      echo stop-failed >>"$FAKE_EVENTS"
      exit 1
    fi
    if [[ "$name" == "dcm-embedding-bge-m3" ]]; then
      echo stop-embedding >>"$FAKE_EVENTS"
    else
      echo stop >>"$FAKE_EVENTS"
    fi
    printf 'false\n' >"$running_file"
    ;;
  start)
    if [[ "${FAKE_START_FAIL:-0}" == 1 ]]; then
      echo start-failed >>"$FAKE_EVENTS"
      exit 1
    fi
    if [[ "$name" == "dcm-embedding-bge-m3" ]]; then
      echo start-embedding >>"$FAKE_EVENTS"
    else
      echo start >>"$FAKE_EVENTS"
    fi
    printf 'true\n' >"$running_file"
    ;;
  logs) echo fake-log ;;
  *) echo "unexpected docker invocation: $*" >&2; exit 1 ;;
esac
EOF

cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
case "$url" in
  *:8081/health) [[ "$(cat "$FAKE_EMBED_RUNNING")" == true ]] ;;
  */health) [[ "$(cat "$FAKE_RUNNING")" == true ]] ;;
  */metrics)
    cat <<METRICS
vllm:num_requests_running{model_name="local-coder"} 0
vllm:num_requests_waiting{model_name="local-coder"} 0
METRICS
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/docker" "$TMP/bin/curl"

export PATH="$TMP/bin:$PATH"
export FAKE_EVENTS="$EVENTS" FAKE_RUNNING="$RUNNING" FAKE_EMBED_RUNNING="$EMBED_RUNNING"
export GPU_JOB_STATE_DIR="$TMP/state"
export GPU_JOB_POLL_SECONDS=0.01 GPU_JOB_READY_POLL_SECONDS=0.01

"$ROOT/gpu-job.sh" run -- bash -c 'echo job >>"$FAKE_EVENTS"'
[[ "$(tr '\n' ' ' <"$EVENTS")" == "stop job start " ]]
grep -q '^result=exit:0$' "$TMP/state/gpu-job.last"
[[ ! -e "$TMP/state/gpu-job.active" ]]

: >"$EVENTS"
printf 'true\n' >"$RUNNING"
printf 'true\n' >"$EMBED_RUNNING"
export FAKE_EMBED_EXISTS=1
"$ROOT/gpu-job.sh" run -- bash -c 'echo dual-job >>"$FAKE_EVENTS"'
[[ "$(tr '\n' ' ' <"$EVENTS")" == "stop-embedding stop dual-job start start-embedding " ]]
grep -q '^vllm_was_running=1$' "$TMP/state/gpu-job.last"
grep -q '^embedding_was_running=1$' "$TMP/state/gpu-job.last"
unset FAKE_EMBED_EXISTS

: >"$EVENTS"
printf 'true\n' >"$RUNNING"
set +e
"$ROOT/gpu-job.sh" run -- bash -c 'echo failed-job >>"$FAKE_EVENTS"; exit 23'
rc=$?
set -e
[[ "$rc" -eq 23 ]]
[[ "$(tr '\n' ' ' <"$EVENTS")" == "stop failed-job start " ]]
grep -q '^result=exit:23$' "$TMP/state/gpu-job.last"

: >"$EVENTS"
printf 'false\n' >"$RUNNING"
"$ROOT/gpu-job.sh" run -- bash -c 'echo offline-job >>"$FAKE_EVENTS"'
[[ "$(cat "$EVENTS")" == "offline-job" ]]
[[ "$(cat "$RUNNING")" == false ]]

cat >"$TMP/state/gpu-job.active" <<EOF
vllm_was_running=1
EOF
"$ROOT/gpu-job.sh" recover
[[ "$(cat "$RUNNING")" == true ]]
grep -q '^result=recovered$' "$TMP/state/gpu-job.last"

: >"$EVENTS"
printf 'true\n' >"$RUNNING"
export FAKE_STOP_FAIL=1
set +e
"$ROOT/gpu-job.sh" run -- bash -c 'echo must-not-run >>"$FAKE_EVENTS"'
rc=$?
set -e
unset FAKE_STOP_FAIL
[[ "$rc" -eq 70 ]]
[[ "$(tr '\n' ' ' <"$EVENTS")" == "stop-failed " ]]
[[ "$(cat "$RUNNING")" == true ]]
[[ ! -e "$TMP/state/gpu-job.active" ]]

: >"$EVENTS"
printf 'true\n' >"$RUNNING"
export FAKE_START_FAIL=1
set +e
"$ROOT/gpu-job.sh" run -- bash -c 'echo restore-failure-job >>"$FAKE_EVENTS"'
rc=$?
set -e
unset FAKE_START_FAIL
[[ "$rc" -eq 70 ]]
[[ "$(tr '\n' ' ' <"$EVENTS")" == "stop restore-failure-job start-failed " ]]
grep -q '^phase=restore_failed$' "$TMP/state/gpu-job.active"
grep -q '^result=restore_failed:70$' "$TMP/state/gpu-job.last"

"$ROOT/gpu-job.sh" recover
[[ "$(cat "$RUNNING")" == true ]]
[[ ! -e "$TMP/state/gpu-job.active" ]]

echo "gpu-job tests passed"
