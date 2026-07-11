#!/bin/bash
# =============================================================================
# Snapshot the CURRENT Aerith model into a self-contained, cloud-deployable
# Docker image. Run anytime (e.g. right after a training run lands and gets
# applied) to refresh what "the cloud version" is.
#
#   ./build_cloud_image.sh                    tags mnemonicai-aerith-cloud:*
#   ./build_cloud_image.sh yourdockerhubuser   tags yourdockerhubuser/mnemonicai-aerith-cloud:*
#
# Produces :<timestamp> and :latest tags. Push whichever you want:
#   docker push yourdockerhubuser/mnemonicai-aerith-cloud:latest
#
# On the cloud GPU (RunPod/Lambda/etc, no host volumes needed):
#   docker run --gpus all -p 8400:8400 yourdockerhubuser/mnemonicai-aerith-cloud:latest
# (mount a volume at /app/mnemonicai_data if you want its learned memory to
# persist across container restarts; otherwise it starts fresh each time.)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

DOCKERHUB_USER="${1:-}"
TAG="$(date +%Y%m%d-%H%M%S)"
BASE_TAG="mnemonicai-base:latest"
IMAGE_NAME="mnemonicai-aerith-cloud"
[ -n "$DOCKERHUB_USER" ] && IMAGE_NAME="$DOCKERHUB_USER/$IMAGE_NAME"

AERITH_SRC=/home/surge/Documents/mergekit/models/Aerith
GGUF_SRC=/home/surge/Documents/MnemonicAi/models/gguf/Aerith-Q4_K_M.gguf
[ -d "$AERITH_SRC" ] || { echo "ERROR: $AERITH_SRC not found" >&2; exit 1; }
[ -f "$GGUF_SRC" ] || { echo "ERROR: $GGUF_SRC not found" >&2; exit 1; }

echo "=== Syncing current Aerith into build context (rsync, incremental after first run)..."
mkdir -p cloud-models/Aerith cloud-models/gguf
rsync -a --info=progress2 --delete "$AERITH_SRC/" cloud-models/Aerith/
rsync -a --info=progress2 "$GGUF_SRC" cloud-models/gguf/Aerith-Q4_K_M.gguf

echo "=== Building base image (app + llama.cpp + deps)..."
docker build -t "$BASE_TAG" -f Dockerfile .

echo "=== Building cloud image (base + baked-in model)..."
docker build -t "${IMAGE_NAME}:${TAG}" -t "${IMAGE_NAME}:latest" \
  --build-arg BASE_IMAGE="$BASE_TAG" -f Dockerfile.cloud .

echo
echo "=== Done. Built: ${IMAGE_NAME}:${TAG} (also tagged :latest)"
echo "    docker push ${IMAGE_NAME}:latest"
echo "    docker push ${IMAGE_NAME}:${TAG}"
echo
echo "On a cloud GPU:"
echo "    docker run --gpus all -p 8400:8400 ${IMAGE_NAME}:latest"
