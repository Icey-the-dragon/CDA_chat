#!/usr/bin/env bash
set -euo pipefail

# Faster (experimental) kubeadm lab using Vagrant's Docker provider.
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
  "${KUBEADM_PREFIX}-worker-grafana"
  "${KUBEADM_PREFIX}-worker-db"
  "${KUBEADM_PREFIX}-worker-chat"
  "${KUBEADM_PREFIX}-worker-nginx"
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
kube label node "${KUBEADM_PREFIX}-worker-grafana" role=grafana --overwrite
kube label node "${KUBEADM_PREFIX}-worker-db" role=db --overwrite
kube label node "${KUBEADM_PREFIX}-worker-chat" role=chat workload=chat --overwrite
kube label node "${KUBEADM_PREFIX}-worker-nginx" role=nginx workload=chat --overwrite

echo "==> Applying application manifests..."
kube apply -f /vagrant/kubernetes/cluster-manifests.yaml -f /vagrant/kubernetes/nginx-configmap.yaml
kube patch deployment/chat-server --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"workload":"chat"}}]'

# Keep the base Prometheus config: its static node targets point at the k3s
# lab IPs and simply won't resolve here, while pod scraping/HPA still work.
kube get configmap prometheus-config -o jsonpath='{.data.prometheus\.yml}' > .kubeadm/prometheus.yml
vagrant ssh "$CP" -c 'cat > /tmp/prometheus.yml' < .kubeadm/prometheus.yml
kube create configmap prometheus-config \
  --from-file=prometheus.yml=/tmp/prometheus.yml --dry-run=client -o yaml | kube apply -f -

kube set env deployment/grafana GF_SERVER_ROOT_URL="http://localhost:18080/grafana/"

echo "==> Waiting for core deployments..."
for deploy in mariadb nats chat-server prometheus grafana nginx-router; do
  kube rollout status "deployment/${deploy}" --timeout=300s || \
    echo "Warning: deployment/${deploy} not ready yet (check: vagrant ssh ${CP} -c 'sudo kubectl get pods -o wide')"
done

echo
kube get nodes -L role,workload -o wide
echo
kube get pods -o wide

cat <<EOF

kubeadm Docker lab is up (experimental).

  Chat UI:      http://localhost:18080/
  Grafana:      http://localhost:18080/grafana/
  kubeconfig:   /etc/kubernetes/admin.conf (inside ${CP})

  Verify:       KUBEADM_DOCKER=1 bash scripts/kubeadm-verify.sh
  Teardown:     bash scripts/kubeadm-down-docker.sh
EOF
