#!/usr/bin/env bash
set -uo pipefail

# Automated fault-injection suite for the 3-node kubeadm lab.
# For every scenario it injects a failure, waits for recovery and verifies the
# application contract: UI/API reachable through either worker + a message can
# be POSTed and read back. All kubectl calls run on the control-plane.
#
# Usage (from host with Vagrant, or inside the controller container):
#   bash scripts/kubeadm-chaos.sh
#   KUBEADM_DOCKER=1 bash scripts/kubeadm-chaos.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# KUBEADM_DOCKER=1 selects the Docker-provider lab (host or controller).
if [[ "${KUBEADM_DOCKER:-0}" == "1" ]]; then
  export VAGRANT_VAGRANTFILE="${ROOT_DIR}/Vagrantfile.kubeadm.docker"
  export VAGRANT_DOTFILE_PATH="${VAGRANT_DOTFILE_PATH:-${ROOT_DIR}/.vagrant-kubeadm-docker}"
  export KUBEADM_PREFIX="kubeadm-docker"
fi
export VAGRANT_VAGRANTFILE="${VAGRANT_VAGRANTFILE:-$ROOT_DIR/Vagrantfile.kubeadm}"
export VAGRANT_DOTFILE_PATH="${VAGRANT_DOTFILE_PATH:-$ROOT_DIR/.vagrant-kubeadm}"

PREFIX="${KUBEADM_PREFIX:-kubeadm}"
CP="${PREFIX}-controlplane"
INFRA_WORKER="${PREFIX}-worker-infra"
APP_WORKER="${PREFIX}-worker-app"
LOG_DIR="$ROOT_DIR/docs/evidence"
mkdir -p "$LOG_DIR"
exec > >(tee "$LOG_DIR/kubeadm-chaos.txt") 2>&1

# Exported OVAs have no Vagrant synced folder; the build keeps a copy on disk.
MANIFEST_DIR="${MANIFEST_DIR:-/vagrant}"
if ! vagrant ssh "$CP" -c \
  'test -f '"$MANIFEST_DIR"'/kubernetes/demo/load-generator.yaml' >/dev/null 2>&1 \
  && vagrant ssh "$CP" -c \
  'test -f /opt/cda-chat/kubernetes/demo/load-generator.yaml' >/dev/null 2>&1; then
  MANIFEST_DIR=/opt/cda-chat
fi

TOTAL=0
FAILED=0

# Host ports 18080/18081 exist on the PC. Inside the controller container the
# Docker network DNS names are used instead; dead candidates are simply skipped.
IFS=', ' read -r -a HEALTH_URLS <<< "${CHAOS_HEALTH_URLS:-http://localhost:18080/api/health,http://localhost:18081/api/health,http://kubeadm-docker-worker-infra:30080/api/health,http://kubeadm-docker-worker-app:30080/api/health}"

pass() { echo "  [OK]   $*"; }
fail() { echo "  [FAIL] $*"; FAILED=$((FAILED + 1)); }
record() {
  local ok="$1"; shift
  TOTAL=$((TOTAL + 1))
  if [ "$ok" -eq 0 ]; then pass "$*"; else fail "$*"; fi
}

kube() {
  local cmd="sudo kubectl"
  local arg escaped
  for arg in "$@"; do
    printf -v escaped '%q' "$arg"
    cmd+=" $escaped"
  done
  vagrant ssh "$CP" -c "$cmd"
}

node_cmd() {
  local node="$1"; shift
  local cmd=""
  local arg escaped
  for arg in "$@"; do
    printf -v escaped '%q' "$arg"
    cmd+=" $escaped"
  done
  vagrant ssh "$node" -c "sudo $cmd"
}

stop_node() {
  local node="$1"
  if [[ "${KUBEADM_DOCKER:-0}" == "1" ]]; then
    docker stop "$node" >/dev/null 2>&1
  else
    vagrant stop "$node" >/dev/null 2>&1
  fi
}

start_node() {
  local node="$1"
  if [[ "${KUBEADM_DOCKER:-0}" == "1" ]]; then
    docker start "$node" >/dev/null 2>&1
  else
    vagrant up "$node" >/dev/null 2>&1
  fi
}

cleanup() {
  echo
  echo "==> Cleanup: making sure every node is running again..."
  for node in "$CP" "$INFRA_WORKER" "$APP_WORKER"; do
    start_node "$node" || true
  done
  wait_for "all nodes Ready" 240 nodes_ready 3 || true
  kube delete job chat-loadgen --ignore-not-found >/dev/null 2>&1 || true
  wait_for "MariaDB target restored to primary" 180 mariadb_target_primary || true
  kube get nodes -o wide 2>/dev/null || true
}
trap cleanup EXIT

wait_for() {
  local desc="$1" timeout="$2"; shift 2
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    if "$@" >/dev/null 2>&1; then
      echo "  [wait] ${desc}: OK after ${elapsed}s"
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  echo "  [wait] ${desc}: TIMEOUT after ${timeout}s"
  return 1
}

nodes_ready() {
  local min="$1"
  local n
  n="$(kube get nodes --no-headers 2>/dev/null \
    | awk '$2 == "Ready" {n++} END {print n+0}')"
  [ "${n:-0}" -ge "$min" ]
}

node_status_ready() {
  local node="$1"
  kube get node "$node" 2>/dev/null | grep -q ' Ready'
}

pods_ready() {
  local selector="$1" min="${2:-1}"
  local n
  n="$(kube get pods -l "$selector" --no-headers 2>/dev/null \
    | awk '$3 == "Running" && $2 ~ /^[0-9]+\/[0-9]+$/ {
        split($2, parts, "/")
        if (parts[1] == parts[2] && parts[1] > 0) n++
      } END {print n+0}')"
  [ "${n:-0}" -ge "$min" ]
}

mariadb_target() {
  kube get svc mariadb-service -o jsonpath='{.spec.selector.app}' 2>/dev/null
}

mariadb_target_replica() {
  [ "$(mariadb_target)" = "mariadb-replica" ]
}

mariadb_target_primary() {
  [ "$(mariadb_target)" = "mariadb-primary" ]
}

mariadb_active_ready() {
  local app
  app="$(mariadb_target)"
  [ -n "$app" ] && pods_ready "app=${app}" 1
}

monitoring_ready() {
  pods_ready app=prometheus 1 && pods_ready app=grafana 1
}

base_url() {
  local url
  for url in "${HEALTH_URLS[@]}"; do
    if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
      printf '%s' "${url%/api/*}"
      return 0
    fi
  done
  return 1
}

# End-to-end check: a fresh message must be stored and readable again.
message_roundtrip() {
  local base body response
  base="$(base_url)" || return 1
  body="chaos-$$-$(date +%s)"
  response="$(curl -fsS --max-time 8 -X POST "${base}/api/messages" \
    -H 'Content-Type: application/json' \
    -d "{\"room\":\"chaos\",\"username\":\"chaos-bot\",\"body\":\"${body}\"}" 2>/dev/null)" || return 1
  printf '%s' "$response" | grep -q "\"body\":\"${body}\"" || return 1
  curl -fsS --max-time 8 "${base}/api/messages?room=chaos&limit=10" 2>/dev/null \
    | grep -q "$body" || return 1
  return 0
}

# Full contract used while the control plane is available.
app_contract() {
  pods_ready app=chat-server 1 || return 1
  pods_ready app=nginx-router 1 || return 1
  pods_ready app=nats 1 || return 1
  mariadb_active_ready || return 1
  message_roundtrip || return 1
  return 0
}

# The API server is down during the control-plane scenario: only user traffic
# can be checked then.
app_contract_live() {
  message_roundtrip || return 1
  return 0
}

scenario() {
  local title="$1"
  echo
  echo "============================================================"
  echo " $title"
  echo "============================================================"
}

echo "============================================================"
echo " kubeadm automated chaos suite - $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================================"
echo " control-plane: $CP"
echo " workers:       $INFRA_WORKER, $APP_WORKER"

if ! vagrant status "$CP" --machine-readable >/dev/null 2>&1; then
  echo "ERROR: Vagrant is not available. Run the kubeadm-up script first." >&2
  exit 1
fi

# ---------------------------------------------------------------- baseline
scenario "0. Baseline: cluster and application healthy"
if wait_for "3 nodes Ready" 120 nodes_ready 3; then record 0 "all 3 nodes are Ready"; else record 1 "nodes did not become Ready"; fi
if wait_for "baseline app contract" 180 app_contract; then record 0 "baseline app contract passed"; else record 1 "baseline app contract failed"; fi
echo "  current MariaDB target: $(mariadb_target)"

# ------------------------------------------------------------- pod deletion
scenario "1. Delete a chat-server pod (self-healing)"
old_pod="$(kube get pods -l app=chat-server --no-headers 2>/dev/null | awk 'NR==1 {print $1}')"
if [ -n "$old_pod" ]; then
  kube delete pod "$old_pod" --grace-period=0 --force >/dev/null 2>&1 || true
  if wait_for "chat pod replacement" 120 pods_ready app=chat-server 2; then record 0 "chat Deployment recreated pod ${old_pod}"; else record 1 "chat pod was not recreated"; fi
  if wait_for "app after chat pod deletion" 120 app_contract; then record 0 "app healthy after chat pod deletion"; else record 1 "app failed after chat pod deletion"; fi
else
  record 1 "no chat pod found for deletion test"
fi

# ------------------------------------------------------------ container kill
scenario "2. Kill PID 1 inside a chat container (liveness restart)"
pod="$(kube get pods -l app=chat-server --no-headers 2>/dev/null | awk 'NR==1 {print $1}')"
if [ -n "$pod" ]; then
  before_restarts="$(kube get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)"
  kube exec "$pod" -- kill 1 >/dev/null 2>&1 || true
  after_restarts="$before_restarts"
  replacement=""
  for _ in $(seq 1 60); do
    after_restarts="$(kube get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "$before_restarts")"
    replacement="$(kube get pods -l app=chat-server --no-headers 2>/dev/null \
      | awk -v old="$pod" '$1 != old && $3 == "Running" {print $1; exit}')"
    if [ "${after_restarts:-0}" -gt "${before_restarts:-0}" ] || [ -n "$replacement" ]; then break; fi
    sleep 3
  done
  if [ "${after_restarts:-0}" -gt "${before_restarts:-0}" ] || [ -n "$replacement" ]; then
    record 0 "chat container/pod restarted after kill 1"
  else
    record 1 "chat container did not restart after kill 1"
  fi
  if wait_for "app after container kill" 120 app_contract; then record 0 "app healthy after container kill"; else record 1 "app failed after container kill"; fi
else
  record 1 "no chat pod found for container-kill test"
fi

# ------------------------------------------------------------- nginx failure
scenario "3. Delete an nginx-router pod (edge redundancy)"
nginx_pod="$(kube get pods -l app=nginx-router --no-headers 2>/dev/null | awk 'NR==1 {print $1}')"
if [ -n "$nginx_pod" ]; then
  kube delete pod "$nginx_pod" --grace-period=0 --force >/dev/null 2>&1 || true
  if wait_for "nginx pod replacement" 120 pods_ready app=nginx-router 2; then record 0 "nginx Deployment recreated pod ${nginx_pod}"; else record 1 "nginx pod was not recreated"; fi
  if wait_for "app after nginx pod deletion" 120 app_contract; then record 0 "app healthy after nginx pod deletion"; else record 1 "app failed after nginx pod deletion"; fi
else
  record 1 "no nginx pod found for deletion test"
fi

# --------------------------------------------------------------- NATS failure
scenario "4. Delete a NATS pod (two-server cluster)"
nats_pod="$(kube get pods -l app=nats --no-headers 2>/dev/null | awk 'NR==1 {print $1}')"
if [ -n "$nats_pod" ]; then
  kube delete pod "$nats_pod" --grace-period=0 --force >/dev/null 2>&1 || true
  if wait_for "NATS pod replacement" 180 pods_ready app=nats 2; then record 0 "NATS StatefulSet recreated pod ${nats_pod}"; else record 1 "NATS pod was not recreated"; fi
  if wait_for "app after NATS pod deletion" 150 app_contract; then record 0 "app healthy after NATS pod deletion"; else record 1 "app failed after NATS pod deletion"; fi
else
  record 1 "no NATS pod found for deletion test"
fi

# ----------------------------------------------------------- app worker down
scenario "5. Stop the app worker (chat/nginx/NATS scale over to infra)"
stop_node "$APP_WORKER"
for _ in $(seq 1 40); do
  if ! node_status_ready "$APP_WORKER"; then break; fi
  sleep 3
done
if ! node_status_ready "$APP_WORKER"; then record 0 "$APP_WORKER is NotReady/gone"; else record 1 "$APP_WORKER is still Ready"; fi
if wait_for "app while app worker is down" 240 app_contract; then record 0 "app healthy with app worker down"; else record 1 "app failed with app worker down"; fi
start_node "$APP_WORKER"
if wait_for "app worker restored" 240 node_status_ready "$APP_WORKER"; then record 0 "$APP_WORKER returned to Ready"; else record 1 "$APP_WORKER did not return to Ready"; fi

# ---------------------------------------------------------- infra worker down
scenario "6. Stop the infra worker (MariaDB primary fails over to replica)"
stop_node "$INFRA_WORKER"
for _ in $(seq 1 40); do
  if ! node_status_ready "$INFRA_WORKER"; then break; fi
  sleep 3
done
if ! node_status_ready "$INFRA_WORKER"; then record 0 "$INFRA_WORKER is NotReady/gone"; else record 1 "$INFRA_WORKER is still Ready"; fi
if wait_for "MariaDB target switched to replica" 180 mariadb_target_replica; then
  record 0 "mariadb-service now points to mariadb-replica"
else
  record 1 "MariaDB failover did not repoint mariadb-service"
fi
if wait_for "app while infra worker is down" 240 app_contract; then record 0 "app healthy with infra worker down"; else record 1 "app failed with infra worker down"; fi
start_node "$INFRA_WORKER"
if wait_for "infra worker restored" 240 node_status_ready "$INFRA_WORKER"; then record 0 "$INFRA_WORKER returned to Ready"; else record 1 "$INFRA_WORKER did not return to Ready"; fi
if wait_for "MariaDB target back to primary" 240 mariadb_target_primary; then
  record 0 "mariadb-service returned to mariadb-primary after recovery"
else
  record 1 "mariadb-service did not fail back to the primary"
fi
if wait_for "app after MariaDB failback" 180 app_contract; then
  record 0 "app healthy after MariaDB failback"
else
  record 1 "app failed after MariaDB failback"
fi

# ----------------------------------------------------------- control plane
scenario "7. Stop the control plane (API down, workloads keep serving)"
stop_node "$CP"
for _ in $(seq 1 30); do
  if ! kube get nodes >/dev/null 2>&1; then break; fi
  sleep 2
done
if ! kube get nodes >/dev/null 2>&1; then record 0 "API is unreachable while control plane is down"; else record 1 "API is still reachable with control plane down"; fi
if wait_for "app while control plane is down" 180 app_contract_live; then record 0 "app healthy with control plane down"; else record 1 "app failed with control plane down"; fi
start_node "$CP"
if wait_for "control plane restored" 300 nodes_ready 3; then record 0 "control plane returned and all nodes Ready"; else record 1 "cluster did not recover after control-plane restart"; fi

# ------------------------------------------------------ DB pod self-healing
scenario "8. Delete the active MariaDB pod (Deployment self-heals)"
active_app="$(mariadb_target)"
active_pod="$(kube get pods -l "app=${active_app}" --no-headers 2>/dev/null | awk 'NR==1 {print $1}')"
if [ -n "$active_pod" ]; then
  kube delete pod "$active_pod" --grace-period=0 --force >/dev/null 2>&1 || true
  if wait_for "MariaDB pod replacement" 240 pods_ready "app=${active_app}" 1; then record 0 "MariaDB pod ${active_pod} was recreated"; else record 1 "MariaDB pod was not recreated"; fi
  if wait_for "app after MariaDB pod deletion" 240 app_contract; then record 0 "app healthy after MariaDB pod deletion"; else record 1 "app failed after MariaDB pod deletion"; fi
else
  record 1 "no active MariaDB pod found for deletion test"
fi

# ------------------------------------------------------- observability loss
scenario "9. Delete Prometheus and Grafana pods (not on the app request path)"
for app in prometheus grafana; do
  pod="$(kube get pods -l "app=${app}" --no-headers 2>/dev/null | awk 'NR==1 {print $1}')"
  if [ -n "$pod" ]; then
    kube delete pod "$pod" --grace-period=0 --force >/dev/null 2>&1 || true
  else
    record 1 "no ${app} pod found for deletion test"
  fi
done
if wait_for "monitoring pods recreated" 240 monitoring_ready; then
  record 0 "Prometheus and Grafana pods were recreated"
else
  record 1 "monitoring pods were not recreated"
fi
if wait_for "app while monitoring was down" 120 app_contract; then
  record 0 "app healthy after observability pods were deleted"
else
  record 1 "app failed when observability pods were deleted"
fi

# ------------------------------------------------- load + pod failure combo
scenario "10. Sustained load while a chat pod is deleted"
kube apply -f "$MANIFEST_DIR/kubernetes/demo/load-generator.yaml" >/dev/null 2>&1 \
  || record 1 "could not start the load generator"
sleep 20
pod="$(kube get pods -l app=chat-server --no-headers 2>/dev/null | awk 'NR==1 {print $1}')"
if [ -n "$pod" ]; then
  kube delete pod "$pod" --grace-period=0 --force >/dev/null 2>&1 || true
else
  record 1 "no chat pod found for load-test deletion"
fi
if wait_for "app under load after pod deletion" 240 app_contract; then
  record 0 "app healthy under load while a chat pod was replaced"
else
  record 1 "app failed under load after chat pod deletion"
fi
replicas="$(kube get hpa chat-server -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || echo 2)"
echo "  HPA desired replicas under load: ${replicas}"
kube delete job chat-loadgen --ignore-not-found >/dev/null 2>&1 || true

echo
echo "============================================================"
echo " checks: ${TOTAL}, failures: ${FAILED}"
if [ "$FAILED" -eq 0 ]; then
  echo " RESULT: all chaos scenarios kept the application available."
else
  echo " RESULT: ${FAILED} check(s) failed. See details above."
fi
echo " Evidence: docs/evidence/kubeadm-chaos.txt"
echo "============================================================"
exit "$FAILED"
