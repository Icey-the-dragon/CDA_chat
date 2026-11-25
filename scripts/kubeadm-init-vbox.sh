#!/usr/bin/env bash
set -uo pipefail

# Configure the 3-node kubeadm lab created by scripts/kubeadm-vbox-lab.sh.
# No Vagrant binary, no Docker and no host kubectl: every command runs inside a
# VM through VBoxManage guestcontrol (scripts/ova-bin/vagrant is a thin shim).
#
#   bash scripts/kubeadm-init-vbox.sh
#
# Node identity comes from the guestproperties set by the lab script, the same
# way the professor's DSBOX images work.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export PATH="$ROOT_DIR/scripts/ova-bin:$PATH"
export OVA_GUEST_USER="${OVA_GUEST_USER:-vagrant}"
export OVA_GUEST_PASSWORD="${OVA_GUEST_PASSWORD:-vagrant}"

CP="kubeadm-controlplane"
INFRA="kubeadm-worker-infra"
APP="kubeadm-worker-app"
ALL=("$CP" "$INFRA" "$APP")

guestprop() {
  VBoxManage guestproperty get "$1" "$2" 2>/dev/null \
    | sed 's/^Value: //' | tr -d '\r'
}

kube() {
  local cmd="sudo kubectl" arg escaped
  for arg in "$@"; do
    printf -v escaped '%q' "$arg"
    cmd+=" $escaped"
  done
  vagrant ssh "$CP" -c "$cmd"
}

node_cmd() {
  local node="$1"; shift
  local cmd="sudo " arg escaped
  for arg in "$@"; do
    printf -v escaped '%q' "$arg"
    cmd+=" $escaped"
  done
  vagrant ssh "$node" -c "$cmd"
}

echo "============================================================"
echo " kubeadm init via VBoxManage guestcontrol"
echo "============================================================"

# Guests must be up before guestcontrol can talk to them.
for vm in "${ALL[@]}"; do
  if ! VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null \
      | grep -q '^VMState="running"'; then
    echo "ERROR: $vm is not running. Run scripts/kubeadm-vbox-lab.sh first." >&2
    exit 1
  fi
done

echo "==> Applying guestproperties (hostname, static IP, /etc/hosts)..."
HOSTS_LINE="$(guestprop "$CP" /CDA/etc_hosts_dump)"
[ -n "$HOSTS_LINE" ] || HOSTS_LINE="kubeadm-controlplane:192.168.56.20,kubeadm-worker-infra:192.168.56.21,kubeadm-worker-app:192.168.56.22"

for vm in "${ALL[@]}"; do
  name="$(guestprop "$vm" /CDA/hostname)"
  ip="$(guestprop "$vm" /CDA/eth0/address)"
  [ -n "$name" ] || name="$vm"
  case "$vm" in
    "$CP")    ip="${ip:-192.168.56.20}" ;;
    "$INFRA") ip="${ip:-192.168.56.21}" ;;
    "$APP")   ip="${ip:-192.168.56.22}" ;;
  esac

  node_cmd "$vm" "hostnamectl set-hostname '$name'"
  node_cmd "$vm" "grep -q 'iface enp0s8' /etc/network/interfaces || printf '\nauto enp0s8\niface enp0s8 inet static\n  address $ip\n  netmask 255.255.255.0\n' >> /etc/network/interfaces"
  node_cmd "$vm" "ip link set enp0s8 up; ip addr add '$ip/24' dev enp0s8 2>/dev/null || true"
  node_cmd "$vm" "grep -q 'kubeadm-controlplane' /etc/hosts || printf '%s\n' '192.168.56.20 kubeadm-controlplane' '192.168.56.21 kubeadm-worker-infra' '192.168.56.22 kubeadm-worker-app' >> /etc/hosts"
  echo "  $vm -> $name ($ip)"
done

CP_IP="$(guestprop "$CP" /CDA/eth0/address)"
CP_IP="${CP_IP:-192.168.56.20}"

echo "==> kubeadm init on $CP ($CP_IP)..."
if ! kube get node "$CP" >/dev/null 2>&1; then
  node_cmd "$CP" "kubeadm init --apiserver-advertise-address='$CP_IP' --pod-network-cidr=10.244.0.0/16"
else
  echo "  control plane already initialized; skipping init"
fi
node_cmd "$CP" "mkdir -p /root/.kube && cp -f /etc/kubernetes/admin.conf /root/.kube/config && chown root:root /root/.kube/config"

echo "==> Flannel CNI (local manifest, interface enp0s8)..."
kube apply -f /opt/cda-chat/kubernetes/kube-flannel.yml >/dev/null
kube patch configmap kube-flannel-cfg -n kube-flannel --type=merge \
  -p '{"data":{"net-conf.json":"{\"Network\":\"10.244.0.0/16\",\"EnableIPv6\":false,\"Backend\":{\"Type\":\"vxlan\"},\"Interface\":\"enp0s8\"}"}}' \
  >/dev/null 2>&1 || \
kube patch configmap kube-flannel-cfg -n kube-system --type=merge \
  -p '{"data":{"net-conf.json":"{\"Network\":\"10.244.0.0/16\",\"EnableIPv6\":false,\"Backend\":{\"Type\":\"vxlan\"},\"Interface\":\"enp0s8\"}"}}' \
  >/dev/null
kube rollout restart daemonset/kube-flannel-ds -n kube-flannel >/dev/null 2>&1 || \
  kube rollout restart daemonset/kube-flannel-ds -n kube-system >/dev/null

echo "==> Joining workers..."
JOIN="$(vagrant ssh "$CP" -c 'sudo kubeadm token create --print-join-command' | tr -d '\r' | tail -1)"
[ -n "$JOIN" ] || { echo "ERROR: no join command from control plane" >&2; exit 1; }
for vm in "$INFRA" "$APP"; do
  if kube get node "$vm" >/dev/null 2>&1; then
    echo "  $vm already joined"
  else
    node_cmd "$vm" "bash -lc '$JOIN'"
  fi
done

echo "==> Waiting for nodes..."
kube wait --for=condition=Ready nodes --all --timeout=300s || exit 1

echo "==> Labels, taints and metrics-server..."
kube label node "$CP" role=control-plane --overwrite >/dev/null
kube taint node "$CP" node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true
kube taint node "$CP" node-role.kubernetes.io/master:NoSchedule- >/dev/null 2>&1 || true
kube label node "$INFRA" role=db monitoring=grafana edge=nginx nats=enabled workload=chat --overwrite >/dev/null
kube label node "$APP" role=chat edge=nginx nats=enabled workload=chat --overwrite >/dev/null

kube apply -f /opt/cda-chat/kubernetes/metrics-server.yaml >/dev/null
if ! kube get deployment metrics-server -n kube-system \
    -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
    | grep -q -- '--kubelet-insecure-tls'; then
  kube patch deployment metrics-server -n kube-system --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' \
    >/dev/null
fi
kube rollout status deployment/metrics-server -n kube-system --timeout=180s >/dev/null || true

echo "==> Applying application manifests..."
kube apply -f /opt/cda-chat/kubernetes/kubeadm/storage.yaml >/dev/null
kube apply -f /opt/cda-chat/kubernetes/cluster-manifests.yaml \
           -f /opt/cda-chat/kubernetes/nginx-configmap.yaml >/dev/null
kube delete deployment/mariadb deployment/nats --ignore-not-found=true >/dev/null 2>&1 || true
kube apply -f /opt/cda-chat/kubernetes/kubeadm/nats.yaml \
           -f /opt/cda-chat/kubernetes/kubeadm/mariadb-ha.yaml >/dev/null
kube patch service mariadb-service -p '{"spec":{"selector":{"app":"mariadb-primary"}}}' >/dev/null

kube patch deployment/chat-server --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"workload":"chat"}}]' >/dev/null
kube patch deployment/prometheus --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"monitoring":"grafana"}}]' >/dev/null
kube patch deployment/grafana --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"monitoring":"grafana"}}]' >/dev/null
kube patch deployment/nginx-router --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"edge":"nginx"}}]' >/dev/null
kube patch deployment/chat-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/affinity","value":{"podAntiAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[{"weight":100,"podAffinityTerm":{"labelSelector":{"matchExpressions":[{"key":"app","operator":"In","values":["chat-server"]}]},"topologyKey":"kubernetes.io/hostname"}}]}}}]' >/dev/null
kube patch deployment/nginx-router --type=json \
  -p '[{"op":"replace","path":"/spec/strategy","value":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}]' >/dev/null
kube patch deployment/nginx-router --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/affinity","value":{"podAntiAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":[{"labelSelector":{"matchExpressions":[{"key":"app","operator":"In","values":["nginx-router"]}]},"topologyKey":"kubernetes.io/hostname"}]}}}]' >/dev/null

kube patch hpa chat-server --type=json \
  -p '[{"op":"replace","path":"/spec/minReplicas","value":2},{"op":"replace","path":"/spec/maxReplicas","value":4}]' >/dev/null
kube scale deployment/chat-server --replicas=2 >/dev/null
kube scale deployment/nginx-router --replicas=2 >/dev/null

kube apply -f /opt/cda-chat/kubernetes/kubeadm/prometheus-config.yaml >/dev/null
kube delete pod -l app=prometheus --wait=false --ignore-not-found >/dev/null 2>&1 || true
kube set env deployment/grafana GF_SERVER_ROOT_URL="http://localhost:18080/grafana/" >/dev/null

echo "==> Waiting for workloads..."
for deploy in mariadb-primary mariadb-replica mariadb-failover chat-server prometheus grafana nginx-router; do
  kube rollout status "deployment/${deploy}" --timeout=300s >/dev/null || \
    echo "  Warning: deployment/${deploy} not ready yet"
done
kube rollout status statefulset/nats --timeout=300s >/dev/null || echo "  Warning: NATS not ready yet"

kube get nodes -o wide
kube get pods -o wide
echo
echo "Cluster ready. Health: http://127.0.0.1:18080/api/health"
