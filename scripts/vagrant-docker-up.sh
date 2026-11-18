#!/usr/bin/env bash
set -euo pipefail

# Run the CDA Chat lab using Vagrant with the Docker provider (containers as
# "VMs" running k3s). This is an experimental alternative to VirtualBox/k3d.
# See Vagrantfile.docker and README for details/limitations.

VAGRANTFILE="Vagrantfile.docker"
NETWORK_NAME="${NETWORK_NAME:-cda-vagrant}"
IMAGE_NAME="${IMAGE_NAME:-chat-server:latest}"
IMAGE_TAR="images/chat-server.tar"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

for cmd in docker vagrant; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

if [ ! -f "$VAGRANTFILE" ]; then
  echo "Error: $VAGRANTFILE not found (run from the repository root)." >&2
  exit 1
fi

echo "==> Ensuring Docker network '${NETWORK_NAME}' exists..."
if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  docker network create "$NETWORK_NAME"
else
  echo "    Network '${NETWORK_NAME}' already exists."
fi

echo "==> Building chat image (${IMAGE_NAME}) and saving to ${IMAGE_TAR}..."
mkdir -p images
docker build -t "$IMAGE_NAME" src/chat-server
docker save -o "$IMAGE_TAR" "$IMAGE_NAME"

echo "==> Bringing up Vagrant Docker cluster..."
vagrant --vagrantfile="$VAGRANTFILE" up --provider=docker

echo
echo "==> Cluster status (best-effort)..."
vagrant --vagrantfile="$VAGRANTFILE" ssh k3s-master -c "sudo k3s kubectl get nodes -L role; echo; sudo k3s kubectl get pods -o wide" || \
  echo "Note: cluster may still be starting; check with: vagrant --vagrantfile=${VAGRANTFILE} ssh k3s-master -c \"sudo k3s kubectl get pods -o wide\""

echo
cat <<EOF
Vagrant Docker cluster is up (experimental).

  Chat UI:      http://localhost:8080/
  Grafana:      http://localhost:8080/grafana/
  Chat health:  http://localhost:8080/api/health

Useful commands:
  vagrant --vagrantfile=${VAGRANTFILE} status
  vagrant --vagrantfile=${VAGRANTFILE} ssh k3s-master -c "sudo k3s kubectl get pods -o wide"

Teardown:
  bash scripts/vagrant-docker-down.sh
EOF
