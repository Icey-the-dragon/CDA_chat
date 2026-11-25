#!/usr/bin/env bash
set -uo pipefail

# Run the 11 fault scenarios against an imported OVA cluster.
# Start it first: bash scripts/launch-ova.sh kubeadm
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT_DIR/scripts/ova-bin:$PATH"
export KUBEADM_OVA=1
export MANIFEST_DIR="${MANIFEST_DIR:-/opt/cda-chat}"
export HEALTH_URLS="${HEALTH_URLS:-http://127.0.0.1:18080/api/health,http://127.0.0.1:18081/api/health,http://127.0.0.1:18082/api/health}"
export CHAOS_HEALTH_URLS="${CHAOS_HEALTH_URLS:-$HEALTH_URLS}"

exec bash "$ROOT_DIR/scripts/kubeadm-chaos.sh" "$@"
