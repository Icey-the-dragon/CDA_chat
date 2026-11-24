#!/usr/bin/env bash
set -uo pipefail

# Tear down via the controller container (host needs Docker only).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IMAGE="${VAGRANT_CONTROLLER_IMAGE:-cda-vagrant-controller}"

docker run --rm -i \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$ROOT_DIR:/workspace" \
  -w /workspace \
  -e NODE_VOLUME_SOURCE="$ROOT_DIR" \
  -e VAGRANT_DOTFILE_PATH=/workspace/.vagrant-kubeadm-docker \
  -e VAGRANT_DEFAULT_PROVIDER=docker \
  "$IMAGE" \
  bash -lc 'bash scripts/kubeadm-down-docker.sh'

# The controller is not attached to the lab network, so it can remove it.
docker network rm cda-kubeadm >/dev/null 2>&1 || true

echo "kubeadm lab removed. k3d/k3s setups were not changed."
