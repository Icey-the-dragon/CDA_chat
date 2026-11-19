#!/usr/bin/env bash
set -uo pipefail

# Tear down via the controller container (host needs Docker only).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IMAGE="${VAGRANT_CONTROLLER_IMAGE:-cda-vagrant-controller}"
NETWORK="cda-kubeadm"

docker run --rm -i \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$ROOT_DIR:/workspace" \
  -w /workspace \
  -e NODE_VOLUME_SOURCE="$ROOT_DIR" \
  -e VAGRANT_DOTFILE_PATH=/workspace/.vagrant-kubeadm-docker \
  "$IMAGE" \
  bash -lc 'bash scripts/kubeadm-down-docker.sh'

# The controller was not attached to this network, so the down script could
# remove it. Clean up here in case it was left behind.
docker network rm "$NETWORK" >/dev/null 2>&1 || true

echo "kubeadm lab removed. k3d/k3s setups were not changed."
