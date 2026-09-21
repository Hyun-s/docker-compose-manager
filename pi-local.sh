#!/usr/bin/env bash
# pi against the local vLLM endpoint, auto-resuming the last session of $PWD.
#
#   pi-local                     resume most recent session for this directory
#                                (starts a new one when there is none)
#   pi-local --new [args...]     force a fresh session
#   pi-local -r | -c | --session <id> | --no-session ...
#                                your own session flag wins, nothing injected
#
# Sessions are bucketed by directory, so running pi-local from a subfolder
# resumes that subfolder's history, not the project root's.

set -euo pipefail

API_ORIGIN="${LOCAL_VLLM_ORIGIN:-http://127.0.0.1:8001}"
if ! curl -fsS --connect-timeout 2 --max-time 3 "$API_ORIGIN/health" >/dev/null 2>&1; then
    echo "Local vLLM is not ready at $API_ORIGIN." >&2
    echo "Start it with: dcm up qwen38-flash-next --vision" >&2
    exit 69
fi

export PI_SKIP_VERSION_CHECK="${PI_SKIP_VERSION_CHECK:-1}"

forward=()
fresh=0
explicit=0
for arg in "$@"; do
    case "$arg" in
        --new) fresh=1; continue ;;
        -c | --continue | -r | --resume | --session | --session-id | --fork | --no-session)
            explicit=1 ;;
    esac
    forward+=("$arg")
done

args=()
if (( fresh == 0 && explicit == 0 )); then
    if [[ -t 1 ]]; then
        # pi encodes the cwd as --path-with-slashes-as-dashes--
        encoded="--${PWD:1}--"
        session_dir="${PI_CODING_AGENT_SESSION_DIR:-$HOME/.pi/agent/sessions}/${encoded//\//-}"
        if [[ -d "$session_dir" ]]; then
            last=$(find "$session_dir" -maxdepth 1 -name '*.jsonl' -printf '%T@ %p\n' |
                sort -rn | head -1 | cut -d' ' -f2-)
            [[ -n "$last" ]] && echo "resuming: $(basename "${last%.jsonl}")"
        fi
    fi
    args=(--continue)
fi

exec pi --provider local-vllm --model local-coder --thinking high "${args[@]}" "${forward[@]}"
