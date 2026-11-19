#!/usr/bin/env bash
set -euo pipefail

# Bring up the parallel kubeadm lab: 1 control-plane + 4 workers, same app
# topology as the default Vagrant/k3s setup but using kubeadm, containerd,
# swap disabled and Flannel CNI. Uses its own Vagrant state directory so it
# does not conflict with the existing Vagrantfile.
#
# kubectl is NOT required on the host: every kubectl call is executed inside
# the control-plane VM through `vagrant ssh`.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VAGRANTFILE="$ROOT_DIR/Vagrantfile.kubeadm"
export VAGRANT_VAGRANTFILE="$VAGRANTFILE"
export VAGRANT_DOTFILE_PATH="$ROOT_DIR/.vagrant-kubeadm"
export K8S_MINOR="${K8S_MINOR:-1.36}"

for cmd in vagrant docker; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

if [ ! -f "$VAGRANTFILE" ]; then
  echo "Error: $VAGRANTFILE not found." >&2
  exit 1
fi

CP="kubeadm-controlplane"
WORKERS=(
  kubeadm-worker-grafana
  kubeadm-worker-db
  kubeadm-worker-chat
  kubeadm-worker-nginx
)

# Run kubectl on the control-plane node, never on the host.
kube() {
  local cmd="sudo kubectl"
  local arg escaped
  for arg in "$@"; do
    printf -v escaped '%q' "$arg"
    cmd+=" $escaped"
  done
  vagrant ssh "$CP" -c "$cmd"
}

mkdir -p .kubeadm images

echo "==> Building chat image (chat-server:latest)..."
docker build -t chat-server:latest src/chat-server
docker save -o images/chat-server.tar chat-server:latest

echo "==> Starting control plane (swap off + containerd + kubeadm init + Flannel)..."
vagrant up "$CP"

echo "==> Fetching a fresh join command from the control plane..."
vagrant ssh "$CP" -c "sudo kubeadm token create --print-join-command" | tr -d '\r' > .kubeadm/join.sh
chmod +x .kubeadm/join.sh

echo "==> Starting workers (they read .kubeadm/join.sh and import the chat image)..."
vagrant up "${WORKERS[@]}"

echo "==> Waiting for all nodes to become Ready..."
kube wait --for=condition=Ready nodes --all --timeout=300s

echo "==> Labeling nodes to match the manifest nodeSelectors..."
kube label node "$CP" role=control-plane --overwrite
# NATS runs on the control-plane node, so remove the NoSchedule taint.
kube taint node "$CP" node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true
kube taint node "$CP" node-role.kubernetes.io/master:NoSchedule- >/dev/null 2>&1 || true
kube label node kubeadm-worker-grafana role=grafana --overwrite
kube label node kubeadm-worker-db role=db --overwrite
kube label node kubeadm-worker-chat role=chat workload=chat --overwrite
kube label node kubeadm-worker-nginx role=nginx workload=chat --overwrite

echo "==> Applying application manifests..."
kube apply -f /vagrant/kubernetes/cluster-manifests.yaml -f /vagrant/kubernetes/nginx-configmap.yaml

# The base manifest pins chat pods to a single role=chat worker. In this lab we
# allow the chat and nginx workers to host chat pods so we can demonstrate
# rescheduling after a worker failure.
kube patch deployment/chat-server --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"workload":"chat"}}]'

# Prometheus' static node targets in the base manifest use the k3s IPs. Point
# them at the kubeadm lab so node metrics work here too. The file is copied
# into the control-plane VM because kubectl only runs there.
kube get configmap prometheus-config -o jsonpath='{.data.prometheus\.yml}' > .kubeadm/prometheus.yml
sed -i 's/192\.168\.56\.1\([0-4]\)/192.168.56.2\1/g' .kubeadm/prometheus.yml
vagrant ssh "$CP" -c 'cat > /tmp/prometheus.yml' < .kubeadm/prometheus.yml
kube create configmap prometheus-config \
  --from-file=prometheus.yml=/tmp/prometheus.yml --dry-run=client -o yaml | kube apply -f -

# The base Grafana root_url assumes host port 8080 (used by k3d). This lab
# publishes 18080 to avoid colliding with the other setups.
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

kubeadm lab is up (K8s v${K8S_MINOR}, 1 control-plane + ${#WORKERS[@]} workers).

  Chat UI:      http://localhost:18080/
  Grafana:      http://localhost:18080/grafana/
  Chat health:  http://localhost:18080/api/health
  kubeconfig:   /etc/kubernetes/admin.conf (inside ${CP})

Useful commands (run from the host, executed on the control plane):
  vagrant ssh ${CP} -c 'sudo kubectl get nodes -o wide'
  vagrant ssh ${CP} -c 'sudo kubectl get hpa chat-server'
  bash scripts/kubeadm-verify.sh

Teardown:
  bash scripts/kubeadm-down.sh
EOF
