#!/usr/bin/env bash
set -euo pipefail

# Bring up the CDA Chat lab as a local multi-node Kubernetes (k3s) cluster
# using k3d (nodes run as Docker containers). This mirrors the Vagrant+k3s
# topology: 1 control-plane/server + 4 agents labeled db/grafana/chat/nginx.

CLUSTER_NAME="${CLUSTER_NAME:-cda-chat}"
IMAGE_NAME="${IMAGE_NAME:-chat-server:latest}"
CONTEXT="k3d-${CLUSTER_NAME}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

for cmd in docker k3d kubectl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is required but not installed." >&2
    case "$cmd" in
      k3d) echo "Install: https://k3d.io/#installation" >&2 ;;
      kubectl) echo "Install: https://kubernetes.io/docs/tasks/tools/" >&2 ;;
    esac
    exit 1
  fi
done

if [ ! -f k3d-cluster.yaml ]; then
  echo "Error: k3d-cluster.yaml not found (run from the repository root)." >&2
  exit 1
fi

echo "==> Building chat image (${IMAGE_NAME})..."
docker build -t "$IMAGE_NAME" src/chat-server

if k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$CLUSTER_NAME"; then
  echo "==> Cluster '${CLUSTER_NAME}' already exists; reusing it."
else
  echo "==> Creating k3d cluster '${CLUSTER_NAME}'..."
  k3d cluster create --config k3d-cluster.yaml
fi

echo "==> Waiting for nodes to be Ready..."
kubectl --context "$CONTEXT" wait --for=condition=Ready nodes --all --timeout=180s

echo "==> Labeling nodes to match Kubernetes manifest nodeSelectors..."
SERVER_NODE="$(kubectl --context "$CONTEXT" get nodes -o name | grep -- '-server-' | head -n1 | sed 's|node/||')"
mapfile -t AGENT_NODES < <(kubectl --context "$CONTEXT" get nodes -o name | grep -- '-agent-' | sed 's|node/||' | sort)

if [ -z "$SERVER_NODE" ] || [ "${#AGENT_NODES[@]}" -lt 4 ]; then
  echo "Error: expected 1 server and at least 4 agent nodes." >&2
  kubectl --context "$CONTEXT" get nodes -o wide >&2
  exit 1
fi

# Control-plane/server node hosts NATS (nodeSelector role=control-plane).
kubectl --context "$CONTEXT" label node "$SERVER_NODE" role=control-plane --overwrite
# k3s server nodes may be tainted NoSchedule by default; NATS must be allowed.
kubectl --context "$CONTEXT" taint node "$SERVER_NODE" node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true
kubectl --context "$CONTEXT" taint node "$SERVER_NODE" node-role.kubernetes.io/master:NoSchedule- >/dev/null 2>&1 || true

# Fixed workers: [0]=grafana (Prometheus+Grafana), [1]=db (MariaDB),
# [2]=chat (autoscaled chat pods), [3]=nginx (edge router / NodePort 30080).
kubectl --context "$CONTEXT" label node "${AGENT_NODES[0]}" role=grafana --overwrite
kubectl --context "$CONTEXT" label node "${AGENT_NODES[1]}" role=db --overwrite
kubectl --context "$CONTEXT" label node "${AGENT_NODES[2]}" role=chat --overwrite
kubectl --context "$CONTEXT" label node "${AGENT_NODES[3]}" role=nginx --overwrite

echo "==> Importing chat image into the cluster..."
k3d image import "$IMAGE_NAME" -c "$CLUSTER_NAME"

echo "==> Applying Kubernetes manifests..."
kubectl --context "$CONTEXT" apply -f kubernetes/cluster-manifests.yaml -f kubernetes/nginx-configmap.yaml

echo "==> Waiting for core deployments (first run may take a while to pull images)..."
for deploy in mariadb nats chat-server prometheus grafana nginx-router; do
  kubectl --context "$CONTEXT" rollout status "deployment/${deploy}" --timeout=300s || \
    echo "Warning: deployment/${deploy} not ready yet (check: kubectl --context ${CONTEXT} get pods -o wide)"
done

echo
kubectl --context "$CONTEXT" get nodes -L role
echo
kubectl --context "$CONTEXT" get pods -o wide
echo

cat <<EOF
Cluster '${CLUSTER_NAME}' is up (kubectl context: ${CONTEXT}).

  Chat UI:      http://localhost:8080/
  Grafana:      http://localhost:8080/grafana/
  Chat health:  http://localhost:8080/api/health

Useful commands:
  kubectl --context ${CONTEXT} get pods -o wide
  kubectl --context ${CONTEXT} get hpa chat-server
  kubectl --context ${CONTEXT} logs deploy/chat-server

After changing chat server code:
  docker build -t ${IMAGE_NAME} src/chat-server
  k3d image import ${IMAGE_NAME} -c ${CLUSTER_NAME}
  kubectl --context ${CONTEXT} rollout restart deployment/chat-server

HPA/load demo:
  kubectl --context ${CONTEXT} apply -f kubernetes/demo/load-generator.yaml

Teardown:
  bash scripts/k3d-down.sh
EOF
