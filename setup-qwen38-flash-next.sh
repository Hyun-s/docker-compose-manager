#!/usr/bin/env bash

# Build the single-DGX-Spark runtime and download the Qwen3.8-Flash-Next
# NVFP4 checkpoint with its n-gram/PLE table kept in BF16. Safe to re-run: the
# clone is pinned and the HF download is resumable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${QWEN38_FLASH_RUNTIME_DIR:-$SCRIPT_DIR/DGX_Spark_Qwen3.8-Flash-Next}"
UPSTREAM_URL="${QWEN38_FLASH_UPSTREAM_URL:-https://github.com/blazux/qwen3.8-Flash-DGX.git}"
UPSTREAM_REF="${QWEN38_FLASH_UPSTREAM_REF:-209646cd98290035ccbddef29b14c460460a8709}"
DOLF_RUNTIME_DIR="${QWEN38_FLASH_DOLF_RUNTIME_DIR:-$SCRIPT_DIR/DGX_Spark_Qwen3.8-Flash-Next-dolf}"
DOLF_UPSTREAM_URL="${QWEN38_FLASH_DOLF_UPSTREAM_URL:-https://github.com/dolf3131/qwen3.8-flash-next-dgx-spark.git}"
DOLF_UPSTREAM_REF="${QWEN38_FLASH_DOLF_UPSTREAM_REF:-1dab83517eb2683d4119eb76eaeb03585e9f8538}"
BASE_IMAGE="${QWEN38_FLASH_BASE_IMAGE:-qwen38-flash-dgx-base}"
IMAGE="${QWEN38_FLASH_IMAGE:-qwen38-flash-dgx}"
MODEL="${QWEN38_FLASH_MODEL:-Inferact/Qwen3.8-Flash-Next-NVFP4}"
HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"

die() {
    echo "Error: $*" >&2
    exit 1
}

command -v git >/dev/null || die "git is required"
command -v docker >/dev/null || die "docker is required"
docker info >/dev/null 2>&1 || die "cannot connect to the Docker daemon"

available_gb=$(df -BG --output=avail "$HF_CACHE" 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -z "$available_gb" ]]; then
    available_gb=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
fi
MODEL_REPO_DIR="$HF_CACHE/hub/models--${MODEL//\//--}"
cached_gb=0
if [[ -d "$MODEL_REPO_DIR" ]]; then
    cached_gb=$(du -sBG "$MODEL_REPO_DIR" | cut -f1 | tr -dc '0-9')
fi
required_gb=$((210 - cached_gb))
(( required_gb < 30 )) && required_gb=30
if (( available_gb < required_gb )); then
    die "at least ${required_gb} GB of free disk space is required to finish setup; ${available_gb} GB is available"
fi

mkdir -p "$(dirname "$RUNTIME_DIR")" "$(dirname "$DOLF_RUNTIME_DIR")" "$HF_CACHE"

checkout_pinned() {
    local url="$1" ref="$2" dir="$3" label="$4"
    if [[ ! -d "$dir/.git" ]]; then
        if [[ -e "$dir" ]]; then
            die "$dir exists but is not a git checkout"
        fi
        echo "Cloning the pinned $label runtime..."
        git clone "$url" "$dir"
    fi
    if ! git -C "$dir" diff --quiet || ! git -C "$dir" diff --cached --quiet; then
        die "$dir has local changes; refusing to overwrite them"
    fi
    echo "Checking out $label commit $ref..."
    git -C "$dir" fetch --depth 1 origin "$ref"
    git -C "$dir" checkout --detach "$ref"
}

checkout_pinned "$UPSTREAM_URL" "$UPSTREAM_REF" "$RUNTIME_DIR" "GB10 mmap"
checkout_pinned "$DOLF_UPSTREAM_URL" "$DOLF_UPSTREAM_REF" "$DOLF_RUNTIME_DIR" "Dolf TP1 GEMM"

echo "Building base Docker image $BASE_IMAGE..."
docker build \
    --label "local-claude-code.qwen38-flash.runtime-ref=$UPSTREAM_REF" \
    -t "$BASE_IMAGE" \
    "$RUNTIME_DIR"

echo "Adding the pinned Dolf TP1 skinny-GEMM optimization to $IMAGE..."
docker build \
    --build-arg "BASE_IMAGE=$BASE_IMAGE" \
    --label "local-claude-code.qwen38-flash.runtime-ref=$UPSTREAM_REF" \
    --label "local-claude-code.qwen38-flash.dolf-ref=$DOLF_UPSTREAM_REF" \
    -t "$IMAGE" \
    -f - "$DOLF_RUNTIME_DIR/scripts" <<'DOCKERFILE'
ARG BASE_IMAGE=qwen38-flash-dgx-base
FROM ${BASE_IMAGE}
COPY patch-skinny-gemm-tp1.py /tmp/patch-skinny-gemm-tp1.py
RUN python3 /tmp/patch-skinny-gemm-tp1.py \
 && python3 -c "import ast,glob; f=glob.glob('/usr/local/lib/python3.*/dist-packages/vllm/models/qwen3_8_flash_next/nvidia/low_latency_gemm.py')[0]; s=open(f).read(); ast.parse(s); assert '(248320, 2560)' in s and '(12, 1)' in s; print('skinny GEMM overlay verified')" \
 && rm /tmp/patch-skinny-gemm-tp1.py
DOCKERFILE

echo "Downloading $MODEL (~170 GB, resumable; BF16 n-gram/PLE)..."
TOKEN_ARGS=()
if [[ -n "${HF_TOKEN:-}" ]]; then
    TOKEN_ARGS+=(-e HF_TOKEN)
elif [[ -n "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
    TOKEN_ARGS+=(-e HUGGING_FACE_HUB_TOKEN -e "HF_TOKEN=$HUGGING_FACE_HUB_TOKEN")
fi

# The BF16 PLE shard is larger than Hugging Face's regular-download limit, so
# unlike the RadixArk-only upstream helper this download must keep hf_xet on.
docker run --rm --name qwen38-flash-download \
    -e HF_HOME=/hf \
    "${TOKEN_ARGS[@]}" \
    -v "$HF_CACHE:/hf" \
    --entrypoint hf "$IMAGE" \
    download "$MODEL" --max-workers 8

echo "Verifying that every n-gram/PLE shard is BF16..."
docker run --rm \
    -e HF_HOME=/hf \
    -v "$HF_CACHE:/hf:ro" \
    --entrypoint python3 "$IMAGE" -c '
import glob, json, os
from safetensors import safe_open
root = "/hf/hub/models--Inferact--Qwen3.8-Flash-Next-NVFP4/snapshots"
snapshots = [p for p in glob.glob(root + "/*") if os.path.isdir(p)]
assert snapshots, "checkpoint snapshot not found"
snapshot = snapshots[0]
with open(os.path.join(snapshot, "model.safetensors.index.json")) as f:
    weight_map = json.load(f)["weight_map"]
ple = {k: v for k, v in weight_map.items() if ".ngram_embedding.shard_" in k}
assert len(ple) == 128, f"expected 128 PLE shards, found {len(ple)}"
for filename in sorted(set(ple.values())):
    path = os.path.join(snapshot, filename)
    names = [name for name, mapped in ple.items() if mapped == filename]
    with safe_open(path, framework="pt", device="cpu") as sf:
        for name in names:
            dtype = str(sf.get_slice(name).get_dtype())
            assert dtype == "BF16", f"{name}: expected BF16, got {dtype}"
print("verified: 128/128 n-gram/PLE shards are BF16")
'

cat <<EOF

Qwen3.8-Flash-Next setup is complete.
Start the multimodal service with:
  $SCRIPT_DIR/docker-compose-manager.sh up qwen38-flash-next

The first model load takes about 8-15 minutes.
EOF
