#!/usr/bin/env bash
set -euo pipefail

# Destroy the Vagrant Docker-provider cluster and remove its Docker network.
# Set REMOVE_NETWORK=0 to keep the Docker network.

VAGRANTFILE="Vagrantfile.docker"
NETWORK_NAME="${NETWORK_NAME:-cda-vagrant}"
REMOVE_NETWORK="${REMOVE_NETWORK:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

for cmd in docker vagrant; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

if [ -f "$VAGRANTFILE" ]; then
  echo "==> Destroying Vagrant Docker cluster..."
  vagrant --vagrantfile="$VAGRANTFILE" destroy -f || true
else
  echo "Warning: $VAGRANTFILE not found; skipping vagrant destroy."
fi

if [ "$REMOVE_NETWORK" = "1" ]; then
  if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    echo "==> Removing Docker network '${NETWORK_NAME}'..."
    docker network rm "$NETWORK_NAME" || echo "Warning: could not remove network '${NETWORK_NAME}' (it may still be in use)."
  else
    echo "Docker network '${NETWORK_NAME}' does not exist."
  fi
else
  echo "Keeping Docker network '${NETWORK_NAME}' (REMOVE_NETWORK=${REMOVE_NETWORK})."
fi

echo "Done."
