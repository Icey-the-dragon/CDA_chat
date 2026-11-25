#!/usr/bin/env bash
set -uo pipefail

# Stop the control plane of an imported OVA cluster and check that the app
# keeps answering through the worker NodePorts.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT_DIR/scripts/ova-bin:$PATH"
export KUBEADM_OVA=1
export HEALTH_URLS="${HEALTH_URLS:-http://127.0.0.1:18080/api/health,http://127.0.0.1:18081/api/health}"

exec bash "$ROOT_DIR/scripts/kubeadm-controlplane-failure.sh" "$@"
