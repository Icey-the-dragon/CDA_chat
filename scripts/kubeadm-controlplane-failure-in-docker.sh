#!/usr/bin/env bash
set -uo pipefail

# Run the control-plane failure test from the Vagrant controller container
# (host has Docker only, no Vagrant installed).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IMAGE="${VAGRANT_CONTROLLER_IMAGE:-cda-vagrant-controller}"
NGINX_CONTAINER="kubeadm-docker-worker-nginx"

# Inside the controller, localhost:18080 is not the host-published port and the
# default bridge has no name-based DNS, so use nginx's bridge IP directly.
NGINX_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NGINX_CONTAINER" 2>/dev/null || true)"
if [ -z "$NGINX_IP" ]; then
  echo "Error: ${NGINX_CONTAINER} is not running. Run scripts/kubeadm-in-docker.sh first." >&2
  exit 1
fi

docker run --rm -i \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$ROOT_DIR:/workspace" \
  -w /workspace \
  -e NODE_VOLUME_SOURCE="$ROOT_DIR" \
  -e VAGRANT_DOTFILE_PATH=/workspace/.vagrant-kubeadm-docker \
  -e KUBEADM_DOCKER=1 \
  -e HEALTH_URL="http://${NGINX_IP}:30080/api/health" \
  "$IMAGE" \
  bash -lc 'bash scripts/kubeadm-controlplane-failure.sh "$@"' _ "$@"
