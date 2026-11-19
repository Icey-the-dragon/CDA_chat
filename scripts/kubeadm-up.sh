#!/usr/bin/env bash
set -euo pipefail

# Bring up the parallel kubeadm lab: 1 control-plane + 4 workers, same app
# topology as the default Vagrant/k3s setup but using kubeadm, containerd,
# swap disabled and Flannel CNI. Uses its own Vagrant state directory so it
# does not conflict with the existing Vagrantfile.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VAGRANTFILE="$ROOT_DIR/Vagrantfile.kubeadm"
export VAGRANT_VAGRANTFILE="$VAGRANTFILE"
export VAGRANT_DOTFILE_PATH="$ROOT_DIR/.vagrant-kubeadm"
export K8S_MINOR="${K8S_MINOR:-1.36}"

for cmd in vagrant docker kubectl; do
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

mkdir -p .kubeadm images

echo "==> Building chat image (chat-server:latest)..."
docker build -t chat-server:latest src/chat-server
docker save -o images/chat-server.tar chat-server:latest

echo "==> Starting control plane (swap off + containerd + kubeadm init + Flannel)..."
vagrant up "$CP"

echo "==> Fetching admin.conf and a fresh join command from the control plane..."
vagrant ssh "$CP" -c "sudo cat /etc/kubernetes/admin.conf" | tr -d '\r' > .kubeadm/admin.conf
chmod 600 .kubeadm/admin.conf
vagrant ssh "$CP" -c "sudo kubeadm token create --print-join-command" | tr -d '\r' > .kubeadm/join.sh
chmod +x .kubeadm/join.sh

echo "==> Starting workers (they read .kubeadm/join.sh and import the chat image)..."
vagrant up "${WORKERS[@]}"

KUBE=(kubectl --kubeconfig "$ROOT_DIR/.kubeadm/admin.conf")

echo "==> Waiting for all nodes to become Ready..."
"${KUBE[@]}" wait --for=condition=Ready nodes --all --timeout=300s

echo "==> Labeling nodes to match the manifest nodeSelectors..."
"${KUBE[@]}" label node "$CP" role=control-plane --overwrite
# NATS runs on the control-plane node, so remove the NoSchedule taint.
"${KUBE[@]}" taint node "$CP" node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true
"${KUBE[@]}" taint node "$CP" node-role.kubernetes.io/master:NoSchedule- >/dev/null 2>&1 || true
"${KUBE[@]}" label node kubeadm-worker-grafana role=grafana --overwrite
"${KUBE[@]}" label node kubeadm-worker-db role=db --overwrite
"${KUBE[@]}" label node kubeadm-worker-chat role=chat workload=chat --overwrite
"${KUBE[@]}" label node kubeadm-worker-nginx role=nginx workload=chat --overwrite

echo "==> Applying application manifests..."
"${KUBE[@]}" apply -f kubernetes/cluster-manifests.yaml -f kubernetes/nginx-configmap.yaml

# The base manifest pins chat pods to a single role=chat worker. In this lab we
# allow the chat and nginx workers to host chat pods so we can demonstrate
# rescheduling after a worker failure.
"${KUBE[@]}" patch deployment/chat-server --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"workload":"chat"}}]'

# Prometheus' static node targets in the base manifest use the k3s IPs. Point
# them at the kubeadm lab so node metrics work here too.
TMP_PROM="$(mktemp)"
"${KUBE[@]}" get configmap prometheus-config -o jsonpath='{.data.prometheus\.yml}' > "$TMP_PROM"
sed -i 's/192\.168\.56\.1\([0-4]\)/192.168.56.2\1/g' "$TMP_PROM"
"${KUBE[@]}" create configmap prometheus-config \
  --from-file=prometheus.yml="$TMP_PROM" --dry-run=client -o yaml | "${KUBE[@]}" apply -f -
rm -f "$TMP_PROM"

# The base Grafana root_url assumes host port 8080 (used by k3d). This lab
# publishes 18080 to avoid colliding with the other setups.
"${KUBE[@]}" set env deployment/grafana GF_SERVER_ROOT_URL="http://localhost:18080/grafana/"

echo "==> Waiting for core deployments..."
for deploy in mariadb nats chat-server prometheus grafana nginx-router; do
  "${KUBE[@]}" rollout status "deployment/${deploy}" --timeout=300s || \
    echo "Warning: deployment/${deploy} not ready yet (check: kubectl --kubeconfig .kubeadm/admin.conf get pods -o wide)"
done

echo
"${KUBE[@]}" get nodes -L role,workload -o wide
echo
"${KUBE[@]}" get pods -o wide

cat <<EOF

kubeadm lab is up (K8s v${K8S_MINOR}, 1 control-plane + ${#WORKERS[@]} workers).

  Chat UI:      http://localhost:18080/
  Grafana:      http://localhost:18080/grafana/
  Chat health:  http://localhost:18080/api/health
  kubeconfig:   .kubeadm/admin.conf

Useful commands:
  kubectl --kubeconfig .kubeadm/admin.conf get nodes -o wide
  kubectl --kubeconfig .kubeadm/admin.conf get hpa chat-server
  bash scripts/kubeadm-verify.sh

Teardown:
  bash scripts/kubeadm-down.sh
EOF
