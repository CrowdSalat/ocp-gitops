#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via environment variables or edit here
# ---------------------------------------------------------------------------
UPSTREAM_VERSION="${UPSTREAM_VERSION:-tc_v0.6.8}"
DOCKERHUB_USER="${DOCKERHUB_USER:-}"
IMAGE_NAME="teddycloud-ocp"
IMAGE_TAG="${IMAGE_TAG:-${UPSTREAM_VERSION}}"

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
if [[ -z "$DOCKERHUB_USER" ]]; then
  echo "ERROR: set DOCKERHUB_USER to your Docker Hub username" >&2
  echo "  export DOCKERHUB_USER=myusername" >&2
  exit 1
fi

FULL_IMAGE="${DOCKERHUB_USER}/${IMAGE_NAME}:${IMAGE_TAG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Building ${FULL_IMAGE}"
podman build \
  --build-arg UPSTREAM_VERSION="${UPSTREAM_VERSION}" \
  --tag "${FULL_IMAGE}" \
  "${SCRIPT_DIR}"

echo "==> Pushing ${FULL_IMAGE}"
podman push "${FULL_IMAGE}"

echo ""
echo "Done. Image available at:"
echo "  docker.io/${FULL_IMAGE}"
echo ""
echo "To verify:"
echo "  podman pull docker.io/${FULL_IMAGE}"
echo "  podman run --rm docker.io/${FULL_IMAGE} getcap /usr/local/bin/teddycloud"
