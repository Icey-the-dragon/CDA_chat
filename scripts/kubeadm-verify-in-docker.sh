#!/usr/bin/env bash
set -uo pipefail

# Run the kubeadm verification from the Vagrant controller container.
# Useful when Vagrant is not installed on the host.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IMAGE="${VAGRANT_CONTROLLER_IMAGE:-cda-vagrant-controller}"

docker run --rm -i \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$ROOT_DIR:/workspace" \
  -w /workspace \
  -e NODE_VOLUME_SOURCE="$ROOT_DIR" \
  -e VAGRANT_DOTFILE_PATH=/workspace/.vagrant-kubeadm-docker \
  -e KUBEADM_DOCKER=1 \
  "$IMAGE" \
  bash -lc 'bash scripts/kubeadm-verify.sh "$@"' _ "$@"
