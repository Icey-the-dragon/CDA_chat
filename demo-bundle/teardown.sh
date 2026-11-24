#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

CLUSTER="${CLUSTER_NAME:-cda-demo}"
PF_PID="${PF_PID:-/tmp/cda-demo-portforward.pid}"

if [ -f "$PF_PID" ]; then
  kill "$(cat "$PF_PID")" 2>/dev/null || true
  rm -f "$PF_PID"
fi

if k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$CLUSTER"; then
  echo "==> Borrando cluster '$CLUSTER'"
  k3d cluster delete "$CLUSTER"
else
  echo "El cluster '$CLUSTER' no existe."
fi

echo "Hecho. La imagen cda-demo:latest sigue disponible en Docker."
