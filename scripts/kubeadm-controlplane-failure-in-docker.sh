#!/usr/bin/env bash
set -uo pipefail

# Run the control-plane failure test from the Vagrant controller container
# (host has Docker only, no Vagrant installed).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IMAGE="${VAGRANT_CONTROLLER_IMAGE:-cda-vagrant-controller}"
NETWORK="cda-kubeadm"
NGINX_CONTAINER="kubeadm-docker-worker-nginx"

if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "Error: Docker network '${NETWORK}' does not exist. Run scripts/kubeadm-in-docker.sh first." >&2
  exit 1
fi

# Inside the controller, localhost:18080 is not the host-published port.
# Reach nginx directly through the Docker network instead.
docker run --rm -i \
  --network "$NETWORK" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$ROOT_DIR:/workspace" \
  -w /workspace \
  -e NODE_VOLUME_SOURCE="$ROOT_DIR" \
  -e VAGRANT_DOTFILE_PATH=/workspace/.vagrant-kubeadm-docker \
  -e KUBEADM_DOCKER=1 \
  -e HEALTH_URL="http://${NGINX_CONTAINER}:30080/api/health" \
  "$IMAGE" \
  bash -lc 'bash scripts/kubeadm-controlplane-failure.sh "$@"' _ "$@"
