#!/usr/bin/env bash
set -uo pipefail

# Verification for the kubeadm lab: environment checks (swap, CNI, Ready),
# HPA scaling, pod failure and worker-node failure. Output is also saved to
# docs/evidence/kubeadm-verify.txt so the results can be used in the report.
#
# kubectl is NOT required on the host: every call runs on the control-plane VM.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# KUBEADM_DOCKER=1 selects the Docker-provider lab without needing a thin
# wrapper script. Works both on a host with Vagrant and inside the controller
# container (ROOT_DIR is /workspace there).
if [[ "${KUBEADM_DOCKER:-0}" == "1" ]]; then
  export VAGRANT_VAGRANTFILE="${ROOT_DIR}/Vagrantfile.kubeadm.docker"
  export VAGRANT_DOTFILE_PATH="${VAGRANT_DOTFILE_PATH:-${ROOT_DIR}/.vagrant-kubeadm-docker}"
  export KUBEADM_PREFIX="kubeadm-docker"
fi

export VAGRANT_VAGRANTFILE="${VAGRANT_VAGRANTFILE:-$ROOT_DIR/Vagrantfile.kubeadm}"
export VAGRANT_DOTFILE_PATH="${VAGRANT_DOTFILE_PATH:-$ROOT_DIR/.vagrant-kubeadm}"

# Default names match the VirtualBox lab; KUBEADM_DOCKER=1 switches them to
# the Docker node names.
PREFIX="${KUBEADM_PREFIX:-kubeadm}"
CP="${PREFIX}-controlplane"
CHAT_WORKER="${PREFIX}-worker-chat"
NGINX_WORKER="${PREFIX}-worker-nginx"
LOG_DIR="$ROOT_DIR/docs/evidence"
mkdir -p "$LOG_DIR"
exec > >(tee "$LOG_DIR/kubeadm-verify.txt") 2>&1

ALL_NODES=(
  "$CP"
  "${PREFIX}-worker-grafana"
  "${PREFIX}-worker-db"
  "$CHAT_WORKER"
  "$NGINX_WORKER"
)
FAILED=0

pass() { echo "  [OK]   $*"; }
fail() { echo "  [FAIL] $*"; FAILED=$((FAILED + 1)); }

kube() {
  local cmd="sudo kubectl"
  local arg escaped
  for arg in "$@"; do
    printf -v escaped '%q' "$arg"
    cmd+=" $escaped"
  done
  vagrant ssh "$CP" -c "$cmd"
}

echo "============================================================"
echo " kubeadm lab verification - $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================================"

if ! vagrant status "$CP" --machine-readable >/dev/null 2>&1; then
  echo "ERROR: Vagrant is not available. Run 'bash scripts/kubeadm-up.sh' first." >&2
  exit 1
fi

echo
echo "==> 1. Node state"
kube get nodes -o wide
for node in "${ALL_NODES[@]}"; do
  if kube get node "$node" 2>/dev/null | grep -q ' Ready'; then
    pass "$node is Ready"
  else
    fail "$node is not Ready"
  fi
done

echo
echo "==> 2. Swap disabled on every node"
for node in "${ALL_NODES[@]}"; do
  swap="$(vagrant ssh "$node" -c 'sudo swapon --show --noheadings' 2>/dev/null | tr -d '\r')"
  if [ -z "$swap" ]; then
    pass "$node has swap disabled"
  else
    fail "$node still reports swap: $swap"
  fi
done

echo
echo "==> 3. CNI (Flannel) pods"
flannel_status="$(kube get pods -A --no-headers 2>/dev/null | awk 'tolower($0) ~ /flannel/ {print $4}')"
if [ -z "$flannel_status" ]; then
  fail "no Flannel pods found"
else
  for status in $flannel_status; do
    if [ "$status" = "Running" ]; then
      pass "Flannel pod Running"
    else
      fail "Flannel pod status is $status"
    fi
  done
  kube get pods -A | grep -i flannel || true
fi

echo
echo "==> 4. Scalability: HPA reacts to load"
kube apply -f /vagrant/kubernetes/demo/load-generator.yaml
desired=1
for _ in $(seq 1 40); do
  desired="$(kube get hpa chat-server -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || echo 1)"
  [ "${desired:-1}" -ge 2 ] && break
  sleep 3
done
kube get hpa chat-server
kube get pods -l app=chat-server -o wide
if [ "${desired:-1}" -ge 2 ]; then
  pass "HPA scaled chat-server to ${desired} replicas under load"
else
  fail "HPA did not scale beyond 1 replica"
fi
kube delete job chat-loadgen --ignore-not-found >/dev/null

echo
echo "==> 5. Failure: deleting a chat pod"
old_pod="$(kube get pods -l app=chat-server --no-headers | awk 'NR==1 {print $1}')"
if [ -z "$old_pod" ]; then
  fail "no chat pod found to delete"
else
  echo "  deleting pod: $old_pod"
  kube delete pod "$old_pod" --grace-period=0 --force >/dev/null
  new_pod=""
  for _ in $(seq 1 30); do
    new_pod="$(kube get pods -l app=chat-server --no-headers \
      | awk -v old="$old_pod" '$1 != old && $3 == "Running" {print $1}' | head -n1)"
    [ -n "$new_pod" ] && break
    sleep 2
  done
  kube get pods -l app=chat-server -o wide
  if [ -n "$new_pod" ]; then
    pass "replacement pod $new_pod is Running (Deployment self-healed)"
  else
    fail "no replacement pod became Running"
  fi
fi

echo
echo "==> 6. Failure: worker node stops (kubelet stopped on chat worker)"
# Keep at least two chat replicas during the test so rescheduling can be seen.
kube patch hpa chat-server --type=json \
  -p '[{"op":"replace","path":"/spec/minReplicas","value":2}]' >/dev/null
kube scale deployment/chat-server --replicas=2 >/dev/null
for _ in $(seq 1 30); do
  ready="$(kube get deployment chat-server -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  [ "${ready:-0}" -ge 2 ] && break
  sleep 2
done
pod_on_chat="$(kube get pods -l app=chat-server -o wide --no-headers \
  | awk -v node="$CHAT_WORKER" '$7 ~ node {print $1}' | head -n1)"

vagrant ssh "$CHAT_WORKER" -c 'sudo systemctl stop kubelet' >/dev/null 2>&1 \
  || fail "could not stop kubelet on $CHAT_WORKER"
for _ in $(seq 1 30); do
  kube get node "$CHAT_WORKER" 2>/dev/null | grep -q 'NotReady' && break
  sleep 5
done
kube get node "$CHAT_WORKER"
if kube get node "$CHAT_WORKER" 2>/dev/null | grep -q 'NotReady'; then
  pass "$CHAT_WORKER became NotReady"
else
  fail "$CHAT_WORKER did not become NotReady"
fi

# Accelerate eviction instead of waiting for the default 5-minute taint timeout.
if [ -n "$pod_on_chat" ]; then
  kube delete pod "$pod_on_chat" --grace-period=0 --force >/dev/null
fi
rescheduled=0
for _ in $(seq 1 30); do
  rescheduled="$(kube get pods -l app=chat-server -o wide --no-headers \
    | awk -v node="$NGINX_WORKER" '$3 == "Running" && $7 ~ node {n++} END {print n+0}')"
  [ "${rescheduled:-0}" -ge 2 ] && break
  sleep 3
done
kube get pods -l app=chat-server -o wide
if [ "${rescheduled:-0}" -ge 2 ]; then
  pass "chat pods rescheduled onto $NGINX_WORKER"
else
  fail "chat pods were not rescheduled onto a healthy worker"
fi

vagrant ssh "$CHAT_WORKER" -c 'sudo systemctl start kubelet' >/dev/null 2>&1 \
  || fail "could not restart kubelet on $CHAT_WORKER"
kube wait --for=condition=Ready "node/$CHAT_WORKER" --timeout=180s >/dev/null \
  || fail "$CHAT_WORKER did not return to Ready"
kube patch hpa chat-server --type=json \
  -p '[{"op":"replace","path":"/spec/minReplicas","value":1}]' >/dev/null

echo
echo "============================================================"
if [ "$FAILED" -eq 0 ]; then
  echo " RESULT: all checks passed."
else
  echo " RESULT: $FAILED check(s) failed. See details above."
fi
echo " Evidence saved to: docs/evidence/kubeadm-verify.txt"
echo "============================================================"

exit "$FAILED"
