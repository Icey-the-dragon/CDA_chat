#!/usr/bin/env bash
set -uo pipefail

# Run the automated chaos suite from the Vagrant controller container
# (host has Docker only, no Vagrant installed).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IMAGE="${VAGRANT_CONTROLLER_IMAGE:-cda-vagrant-controller}"
NETWORK="cda-kubeadm"
CONTROLLER_IP="172.28.0.2"

if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "Error: Docker network '${NETWORK}' does not exist. Run scripts/kubeadm-in-docker.sh first." >&2
  exit 1
fi

docker run --rm -i \
  --network "$NETWORK" --ip "$CONTROLLER_IP" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$ROOT_DIR:/workspace" \
  -w /workspace \
  -e NODE_VOLUME_SOURCE="$ROOT_DIR" \
  -e VAGRANT_DOTFILE_PATH=/workspace/.vagrant-kubeadm-docker \
  -e KUBEADM_DOCKER=1 \
  "$IMAGE" \
  bash -lc 'bash scripts/kubeadm-chaos.sh "$@"' _ "$@"
