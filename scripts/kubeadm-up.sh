#!/usr/bin/env bash
set -euo pipefail

# Bring up the parallel kubeadm lab: 1 control-plane + 2 workers, as required
# by the assignment. The workers consolidate the app services (infra: DB and
# monitoring; app: nginx and chat), use kubeadm/containerd, swap disabled and
# Flannel CNI. Uses its own Vagrant state directory so it does not conflict
# with the existing Vagrantfile.
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
  kubeadm-worker-infra
  kubeadm-worker-app
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

echo "==> Labeling nodes to match the kubeadm nodeSelectors..."
kube label node "$CP" role=control-plane --overwrite
# The failover controller is scheduled on the control-plane, so remove the
# NoSchedule taint (NATS itself now runs on the two workers).
kube taint node "$CP" node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true
kube taint node "$CP" node-role.kubernetes.io/master:NoSchedule- >/dev/null 2>&1 || true
# infra: MariaDB primary (role=db) + Prometheus/Grafana + nginx/NATS/chat.
kube label node kubeadm-worker-infra role=db monitoring=grafana edge=nginx nats=enabled workload=chat --overwrite
# app: nginx, chat, load generator, MariaDB replica and NATS.
kube label node kubeadm-worker-app role=chat edge=nginx nats=enabled workload=chat --overwrite

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
kube apply -f /vagrant/kubernetes/cluster-manifests.yaml -f /vagrant/kubernetes/nginx-configmap.yaml

# Replace the single-instance base MariaDB/NATS with kubeadm HA variants.
kube delete deployment/mariadb deployment/nats --ignore-not-found=true >/dev/null 2>&1 || true
kube apply -f /vagrant/kubernetes/kubeadm/nats.yaml \
           -f /vagrant/kubernetes/kubeadm/mariadb-ha.yaml
kube patch service mariadb-service \
  -p '{"spec":{"selector":{"app":"mariadb-primary"}}}'

# With only two workers, each one hosts several services. Use extra label keys
# (monitoring/edge/workload/nats) instead of overloading the single `role` key.
kube patch deployment/chat-server --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"workload":"chat"}}]'
kube patch deployment/prometheus --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"monitoring":"grafana"}}]'
kube patch deployment/grafana --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"monitoring":"grafana"}}]'
kube patch deployment/nginx-router --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"edge":"nginx"}}]'
# Spread the redundant replicas across the two workers. Chat uses a preferred
# rule so the HPA can still grow past two pods on a larger cluster.
kube patch deployment/chat-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/affinity","value":{"podAntiAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[{"weight":100,"podAffinityTerm":{"labelSelector":{"matchExpressions":[{"key":"app","operator":"In","values":["chat-server"]}]},"topologyKey":"kubernetes.io/hostname"}}]}}}]'
kube patch deployment/nginx-router --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/affinity","value":{"podAntiAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":[{"labelSelector":{"matchExpressions":[{"key":"app","operator":"In","values":["nginx-router"]}]},"topologyKey":"kubernetes.io/hostname"}]}}}]'

# Keep two chat/nginx replicas from the start so losing either worker is not a
# full outage. The HPA can still scale up to 4 under load.
kube patch hpa chat-server --type=json \
  -p '[{"op":"replace","path":"/spec/minReplicas","value":2},{"op":"replace","path":"/spec/maxReplicas","value":4}]'
kube scale deployment/chat-server --replicas=2 >/dev/null
kube scale deployment/nginx-router --replicas=2 >/dev/null

# The shared Prometheus ConfigMap keeps the k3s targets untouched. This lab
# applies its own 3-node version from kubeadm/prometheus-config.yaml. Restart
# the pod so Prometheus picks up the mounted ConfigMap immediately.
kube apply -f /vagrant/kubernetes/kubeadm/prometheus-config.yaml
kube delete pod -l app=prometheus --wait=false --ignore-not-found >/dev/null 2>&1 || true

# The base Grafana root_url assumes host port 8080 (used by k3d). This lab
# publishes 18080/18081 on the two workers.
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

kubeadm lab is up (K8s v${K8S_MINOR}, 1 control-plane + ${#WORKERS[@]} workers).

  Chat UI:      http://localhost:18080/  (infra worker)
                http://localhost:18081/  (app worker)
  Grafana:      http://localhost:18080/grafana/
  Chat health:  http://localhost:18080/api/health
  kubeconfig:   /etc/kubernetes/admin.conf (inside ${CP})

Useful commands (run from the host, executed on the control plane):
  vagrant ssh ${CP} -c 'sudo kubectl get nodes -o wide'
  vagrant ssh ${CP} -c 'sudo kubectl get hpa chat-server'
  bash scripts/kubeadm-verify.sh
  bash scripts/kubeadm-chaos.sh

Teardown:
  bash scripts/kubeadm-down.sh
EOF
