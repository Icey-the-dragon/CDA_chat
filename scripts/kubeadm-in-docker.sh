#!/usr/bin/env bash
set -euo pipefail

# Use case: the PC has Docker but NOT Vagrant installed.
# This builds a small controller image that contains Vagrant + Docker CLI, then
# runs the normal kubeadm Docker-provider flow from inside that container.
# The node containers are created on the HOST Docker daemon (Docker-outside-of-
# Docker), so they survive after this controller container exits.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

for cmd in docker; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

IMAGE="${VAGRANT_CONTROLLER_IMAGE:-cda-vagrant-controller}"

echo "==> Building Vagrant controller image (${IMAGE})..."
docker build -t "$IMAGE" docker/vagrant-controller

echo "==> Running kubeadm-up-docker.sh inside the controller container..."
echo "    (Vagrant is not installed on the host; only Docker is used.)"
docker run --rm -i \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$ROOT_DIR:/workspace" \
  -w /workspace \
  -e NODE_VOLUME_SOURCE="$ROOT_DIR" \
  -e VAGRANT_DOTFILE_PATH=/workspace/.vagrant-kubeadm-docker \
  -e K8S_MINOR="${K8S_MINOR:-1.36}" \
  -e KUBEADM_NODE_IMAGE="${KUBEADM_NODE_IMAGE:-cda-kubeadm-node}" \
  "$IMAGE" \
  bash -lc 'bash scripts/kubeadm-up-docker.sh'

echo
echo "kubeadm lab is up. The controller container has exited; the 5 node"
echo "containers keep running on the host Docker daemon."
echo
echo "  Verify:   bash scripts/kubeadm-verify-in-docker.sh"
echo "  Teardown: bash scripts/kubeadm-down-in-docker.sh"
