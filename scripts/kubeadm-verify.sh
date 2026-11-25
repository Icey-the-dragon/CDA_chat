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
APP_WORKER="${PREFIX}-worker-app"
INFRA_WORKER="${PREFIX}-worker-infra"
LOG_DIR="$ROOT_DIR/docs/evidence"
mkdir -p "$LOG_DIR"
exec > >(tee "$LOG_DIR/kubeadm-verify.txt") 2>&1

# Inside an exported OVA there is no Vagrant synced folder. The build copies
# the manifests to /opt/cda-chat so the same commands still work.
MANIFEST_DIR="${MANIFEST_DIR:-/vagrant}"
if ! vagrant ssh "$CP" -c \
  'test -f '"$MANIFEST_DIR"'/kubernetes/demo/load-generator.yaml' >/dev/null 2>&1 \
  && vagrant ssh "$CP" -c \
  'test -f /opt/cda-chat/kubernetes/demo/load-generator.yaml' >/dev/null 2>&1; then
  MANIFEST_DIR=/opt/cda-chat
fi

# Try every published worker port, plus the Docker network DNS names when the
# script runs inside the controller container.
HEALTH_URLS="${HEALTH_URLS:-http://localhost:18080/api/health,http://localhost:18081/api/health,http://kubeadm-docker-worker-infra:30080/api/health,http://kubeadm-docker-worker-app:30080/api/health}"
IFS=', ' read -r -a health_urls <<< "$HEALTH_URLS"

ALL_NODES=(
  "$CP"
  "$INFRA_WORKER"
  "$APP_WORKER"
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

pods_ready() {
  local selector="$1" min="${2:-1}" n
  n="$(kube get pods -l "$selector" --no-headers 2>/dev/null \
    | awk '$3 == "Running" && $2 ~ /^[0-9]+\/[0-9]+$/ {
        split($2, parts, "/")
        if (parts[1] == parts[2] && parts[1] > 0) n++
      } END {print n+0}')"
  [ "${n:-0}" -ge "$min" ]
}

base_url() {
  local url
  for url in "${health_urls[@]}"; do
    if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
      printf '%s' "${url%/api/*}"
      return 0
    fi
  done
  return 1
}

api_roundtrip() {
  local base body response
  base="$(base_url)" || return 1
  body="verify-$$-$(date +%s)"
  response="$(curl -fsS --max-time 8 -X POST "${base}/api/messages" \
    -H 'Content-Type: application/json' \
    -d "{\"room\":\"chaos\",\"username\":\"verify-bot\",\"body\":\"${body}\"}" 2>/dev/null)" || return 1
  printf '%s' "$response" | grep -q "\"body\":\"${body}\"" || return 1
  curl -fsS --max-time 8 "${base}/api/messages?room=chaos&limit=10" 2>/dev/null \
    | grep -q "$body" || return 1
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
if [[ "${KUBEADM_DOCKER:-0}" == "1" ]]; then
  echo "==> 2. kubelet swap check disabled (host swap cannot be turned off in a container)"
  for node in "${ALL_NODES[@]}"; do
    # The Docker image sets the flag in /etc/default/kubelet (which wins over
    # kubelet.service.d because of EnvironmentFile); VirtualBox uses a drop-in.
    if vagrant ssh "$node" -c \
        'grep -Rqs -- "--fail-swap-on=false" /etc/systemd/system/kubelet.service.d || grep -qs -- "--fail-swap-on=false" /etc/default/kubelet' >/dev/null 2>&1; then
      pass "$node kubelet ignores host swap (--fail-swap-on=false)"
    else
      fail "$node is missing the kubelet swap drop-in"
    fi
  done
else
  echo "==> 2. Swap disabled on every node"
  for node in "${ALL_NODES[@]}"; do
    swap="$(vagrant ssh "$node" -c 'sudo swapon --show --noheadings' 2>/dev/null | tr -d '\r')"
    if [ -z "$swap" ]; then
      pass "$node has swap disabled"
    else
      fail "$node still reports swap: $swap"
    fi
  done
fi

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
echo "==> 3b. Redundant workloads and end-to-end API"
for entry in mariadb-primary:1 mariadb-replica:1 mariadb-failover:1 nats:2 nginx-router:2 chat-server:2; do
  app="${entry%%:*}"
  min="${entry##*:}"
  if pods_ready "app=${app}" "$min"; then
    pass "${app}: at least ${min} pod(s) Ready"
  else
    fail "${app}: fewer than ${min} pod(s) Ready"
  fi
done
db_target="$(kube get svc mariadb-service -o jsonpath='{.spec.selector.app}' 2>/dev/null || true)"
if [ "$db_target" = "mariadb-primary" ]; then
  pass "mariadb-service points to mariadb-primary"
else
  fail "mariadb-service target is '${db_target}', expected mariadb-primary"
fi
if api_roundtrip; then
  pass "message POST + GET round-trip succeeded through nginx"
else
  fail "message round-trip failed through ${HEALTH_URLS}"
fi

echo
echo "==> 4. Scalability: HPA reacts to load"
if kube get apiservice v1beta1.metrics.k8s.io 2>/dev/null | grep -q ' True '; then
  pass "metrics API is available"
else
  fail "metrics API is not available (check metrics-server on the control plane)"
fi
kube apply -f "$MANIFEST_DIR/kubernetes/demo/load-generator.yaml"
baseline="$(kube get hpa chat-server -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || echo 2)"
desired="$baseline"
for _ in $(seq 1 40); do
  desired="$(kube get hpa chat-server -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || echo "$baseline")"
  [ "${desired:-$baseline}" -gt "$baseline" ] && break
  sleep 3
done
kube get hpa chat-server
kube get pods -l app=chat-server -o wide
if [ "${desired:-$baseline}" -gt "$baseline" ]; then
  pass "HPA scaled chat-server from ${baseline} to ${desired} replicas under load"
else
  fail "HPA did not scale beyond the ${baseline} baseline"
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
echo "==> 6. Failure: worker node stops (kubelet stopped on app worker: nginx + chat)"
# nginx goes down with this worker; the check below focuses on the chat pods
# moving to the surviving infra worker (both workers have workload=chat).
# Keep at least two chat replicas during the test so rescheduling can be seen.
kube patch hpa chat-server --type=json \
  -p '[{"op":"replace","path":"/spec/minReplicas","value":2}]' >/dev/null
kube scale deployment/chat-server --replicas=2 >/dev/null
for _ in $(seq 1 30); do
  ready="$(kube get deployment chat-server -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  [ "${ready:-0}" -ge 2 ] && break
  sleep 2
done
pod_on_app="$(kube get pods -l app=chat-server -o wide --no-headers \
  | awk -v node="$APP_WORKER" '$7 ~ node {print $1}' | head -n1)"

vagrant ssh "$APP_WORKER" -c 'sudo systemctl stop kubelet' >/dev/null 2>&1 \
  || fail "could not stop kubelet on $APP_WORKER"
for _ in $(seq 1 30); do
  kube get node "$APP_WORKER" 2>/dev/null | grep -q 'NotReady' && break
  sleep 5
done
kube get node "$APP_WORKER"
if kube get node "$APP_WORKER" 2>/dev/null | grep -q 'NotReady'; then
  pass "$APP_WORKER became NotReady"
else
  fail "$APP_WORKER did not become NotReady"
fi

# Accelerate eviction instead of waiting for the default 5-minute taint timeout.
if [ -n "$pod_on_app" ]; then
  kube delete pod "$pod_on_app" --grace-period=0 --force >/dev/null
fi
rescheduled=0
for _ in $(seq 1 30); do
  rescheduled="$(kube get pods -l app=chat-server -o wide --no-headers \
    | awk -v node="$INFRA_WORKER" '$3 == "Running" && $7 ~ node {n++} END {print n+0}')"
  [ "${rescheduled:-0}" -ge 2 ] && break
  sleep 3
done
kube get pods -l app=chat-server -o wide
if [ "${rescheduled:-0}" -ge 2 ]; then
  pass "chat pods rescheduled onto $INFRA_WORKER"
else
  fail "chat pods were not rescheduled onto a healthy worker"
fi

vagrant ssh "$APP_WORKER" -c 'sudo systemctl start kubelet' >/dev/null 2>&1 \
  || fail "could not restart kubelet on $APP_WORKER"
kube wait --for=condition=Ready "node/$APP_WORKER" --timeout=180s >/dev/null \
  || fail "$APP_WORKER did not return to Ready"
kube patch hpa chat-server --type=json \
  -p '[{"op":"replace","path":"/spec/minReplicas","value":2}]' >/dev/null

echo
echo "==> 7. Final application check after recovery"
if api_roundtrip; then
  pass "chat API still accepts and returns messages after the failure test"
else
  fail "chat API did not recover after the failure test"
fi

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
