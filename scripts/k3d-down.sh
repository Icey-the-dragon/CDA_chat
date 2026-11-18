#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-cda-chat}"

if ! command -v k3d >/dev/null 2>&1; then
  echo "Error: 'k3d' is required but not installed." >&2
  exit 1
fi

if k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$CLUSTER_NAME"; then
  echo "==> Deleting k3d cluster '${CLUSTER_NAME}'..."
  k3d cluster delete "$CLUSTER_NAME"
  echo "Deleted cluster '${CLUSTER_NAME}'."
else
  echo "Cluster '${CLUSTER_NAME}' does not exist."
fi
