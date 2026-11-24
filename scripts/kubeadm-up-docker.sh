#!/usr/bin/env bash
set -euo pipefail

# Faster (experimental) kubeadm lab using Vagrant's Docker provider.
# Topology: 1 control-plane + 2 workers (services consolidated on the workers).
# The host needs Vagrant + Docker only; kubectl runs inside the control-plane.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export VAGRANT_VAGRANTFILE="$ROOT_DIR/Vagrantfile.kubeadm.docker"
export VAGRANT_DOTFILE_PATH="$ROOT_DIR/.vagrant-kubeadm-docker"
export KUBEADM_PREFIX="kubeadm-docker"
export KUBEADM_NODE_IMAGE="${KUBEADM_NODE_IMAGE:-cda-kubeadm-node}"
export K8S_MINOR="${K8S_MINOR:-1.36}"

for cmd in vagrant docker; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

CP="${KUBEADM_PREFIX}-controlplane"
WORKERS=(
  "${KUBEADM_PREFIX}-worker-infra"
  "${KUBEADM_PREFIX}-worker-app"
)

kube() {
  local cmd="sudo kubectl"
  local arg escaped
  for arg in "$@"; do
    printf -v escaped '%q' "$arg"
    cmd+=" $escaped"
  done
  vagrant ssh "$CP" -c "$cmd"
}

echo "==> Ensuring isolated network 'cda-kubeadm' (172.28.0.0/16) exists..."
docker network inspect cda-kubeadm >/dev/null 2>&1 || \
  docker network create --subnet 172.28.0.0/16 cda-kubeadm

echo "==> Building node image ${KUBEADM_NODE_IMAGE} (K8s v${K8S_MINOR})..."
docker build \
  --build-arg "K8S_MINOR=${K8S_MINOR}" \
  --build-arg "CONTAINERD_SNAPSHOTTER=${CONTAINERD_SNAPSHOTTER:-overlayfs}" \
  -t "$KUBEADM_NODE_IMAGE" \
  docker/kubeadm-node

mkdir -p .kubeadm images

echo "==> Building chat image and saving it for the worker containers..."
docker build -t chat-server:latest src/chat-server
docker save -o images/chat-server.tar chat-server:latest

echo "==> Starting control-plane container..."
vagrant up --provider=docker "$CP"

echo "==> Fetching join command (ignoring the host-swap preflight inside containers)..."
vagrant ssh "$CP" -c "sudo kubeadm token create --print-join-command" \
  | tr -d '\r' \
  | sed 's/$/ --ignore-preflight-errors=Swap/' > .kubeadm/join.sh
chmod +x .kubeadm/join.sh

echo "==> Starting worker containers..."
vagrant up --provider=docker "${WORKERS[@]}"

echo "==> Waiting for all nodes to become Ready..."
kube wait --for=condition=Ready nodes --all --timeout=300s

echo "==> Labeling nodes..."
kube label node "$CP" role=control-plane --overwrite
kube taint node "$CP" node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true
kube taint node "$CP" node-role.kubernetes.io/master:NoSchedule- >/dev/null 2>&1 || true
kube label node "${KUBEADM_PREFIX}-worker-infra" role=db monitoring=grafana edge=nginx nats=enabled workload=chat --overwrite
kube label node "${KUBEADM_PREFIX}-worker-app" role=chat edge=nginx nats=enabled workload=chat --overwrite

echo "==> Installing metrics-server (required by the HPA v2)..."
kube apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
if ! kube get deployment metrics-server -n kube-system \
    -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
    | grep -q -- '--kubelet-insecure-tls'; then
  kube patch deployment metrics-server -n kube-system --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' \
    >/dev/null
fi
kube rollout status deployment/metrics-server -n kube-system --timeout=180s

echo "==> Applying application manifests..."
# Plain kubeadm has no dynamic provisioner; these hostPath PVs back the PVCs.
kube apply -f /vagrant/kubernetes/kubeadm/storage.yaml
kube apply -f /vagrant/kubernetes/cluster-manifests.yaml -f /vagrant/kubernetes/nginx-configmap.yaml

# Replace the single-instance base MariaDB/NATS with kubeadm HA variants.
kube delete deployment/mariadb deployment/nats --ignore-not-found=true >/dev/null 2>&1 || true
kube apply -f /vagrant/kubernetes/kubeadm/nats.yaml \
           -f /vagrant/kubernetes/kubeadm/mariadb-ha.yaml
kube patch service mariadb-service \
  -p '{"spec":{"selector":{"app":"mariadb-primary"}}}'

kube patch deployment/chat-server --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"workload":"chat"}}]'
kube patch deployment/prometheus --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"monitoring":"grafana"}}]'
kube patch deployment/grafana --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"monitoring":"grafana"}}]'
kube patch deployment/nginx-router --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"edge":"nginx"}}]'
# Spread the redundant replicas across the two workers.
kube patch deployment/chat-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/affinity","value":{"podAntiAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[{"weight":100,"podAffinityTerm":{"labelSelector":{"matchExpressions":[{"key":"app","operator":"In","values":["chat-server"]}]},"topologyKey":"kubernetes.io/hostname"}}]}}}]'
# Keep the two nginx pods on different workers. A hard anti-affinity plus the
# default maxSurge=1 deadlocks the 1 -> 2 replica rollout on only two workers:
# the old pod occupies one node and the surge pod cannot be placed on the other.
# maxSurge=0 removes the old pod before creating the replacement.
kube patch deployment/nginx-router --type=json \
  -p '[{"op":"replace","path":"/spec/strategy","value":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}]'
kube patch deployment/nginx-router --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/affinity","value":{"podAntiAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":[{"labelSelector":{"matchExpressions":[{"key":"app","operator":"In","values":["nginx-router"]}]},"topologyKey":"kubernetes.io/hostname"}]}}}]'

# Two chat/nginx replicas from the start: one per worker. HPA can reach 4.
kube patch hpa chat-server --type=json \
  -p '[{"op":"replace","path":"/spec/minReplicas","value":2},{"op":"replace","path":"/spec/maxReplicas","value":4}]'
kube scale deployment/chat-server --replicas=2 >/dev/null
kube scale deployment/nginx-router --replicas=2 >/dev/null

# Docker's user-defined network resolves node names, so use DNS targets here.
# Restart the pod so Prometheus picks up the mounted ConfigMap immediately.
kube apply -f /vagrant/kubernetes/kubeadm/prometheus-config-docker.yaml
kube delete pod -l app=prometheus --wait=false --ignore-not-found >/dev/null 2>&1 || true

kube set env deployment/grafana GF_SERVER_ROOT_URL="http://localhost:18080/grafana/"

echo "==> Waiting for core workloads..."
for deploy in mariadb-primary mariadb-replica mariadb-failover chat-server prometheus grafana nginx-router; do
  kube rollout status "deployment/${deploy}" --timeout=300s || \
    echo "Warning: deployment/${deploy} not ready yet (check: vagrant ssh ${CP} -c 'sudo kubectl get pods -o wide')"
done
kube rollout status statefulset/nats --timeout=300s || \
  echo "Warning: NATS StatefulSet not ready yet"

echo
kube get nodes -L role,workload,monitoring,edge,nats -o wide
echo
kube get pods -o wide

cat <<EOF

kubeadm Docker lab is up (experimental: 1 control-plane + ${#WORKERS[@]} workers).

  Chat UI:      http://localhost:18080/  (infra worker)
                http://localhost:18081/  (app worker)
  Grafana:      http://localhost:18080/grafana/
  kubeconfig:   /etc/kubernetes/admin.conf (inside ${CP})

  Verify:       KUBEADM_DOCKER=1 bash scripts/kubeadm-verify.sh
  Chaos:        KUBEADM_DOCKER=1 bash scripts/kubeadm-chaos.sh
  Teardown:     bash scripts/kubeadm-down-docker.sh
EOF
