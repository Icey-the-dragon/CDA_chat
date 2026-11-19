#!/usr/bin/env bash
set -uo pipefail

# Run the kubeadm verification from the Vagrant controller container.
# Useful when Vagrant is not installed on the host.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IMAGE="${VAGRANT_CONTROLLER_IMAGE:-cda-vagrant-controller}"
NETWORK="cda-kubeadm"

if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "Error: Docker network '${NETWORK}' does not exist. Run scripts/kubeadm-in-docker.sh first." >&2
  exit 1
fi

docker run --rm -i \
  --network "$NETWORK" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$ROOT_DIR:/workspace" \
  -w /workspace \
  -e NODE_VOLUME_SOURCE="$ROOT_DIR" \
  -e VAGRANT_DOTFILE_PATH=/workspace/.vagrant-kubeadm-docker \
  "$IMAGE" \
  bash -lc 'bash scripts/kubeadm-verify-docker.sh "$@"' _ "$@"
