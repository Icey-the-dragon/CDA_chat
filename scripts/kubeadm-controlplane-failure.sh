#!/usr/bin/env bash
set -uo pipefail

# Optional disruptive test: stop the single control-plane node, observe that
# running workloads stay up but the API is unavailable, then restore it.
# This script is intentionally separate from kubeadm-verify.sh.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export VAGRANT_VAGRANTFILE="$ROOT_DIR/Vagrantfile.kubeadm"
export VAGRANT_DOTFILE_PATH="$ROOT_DIR/.vagrant-kubeadm"

KUBE=(kubectl --kubeconfig "$ROOT_DIR/.kubeadm/admin.conf")
CP="kubeadm-controlplane"
LOG_DIR="$ROOT_DIR/docs/evidence"
mkdir -p "$LOG_DIR"
exec > >(tee "$LOG_DIR/kubeadm-controlplane-failure.txt") 2>&1

FAILED=0
pass() { echo "  [OK]   $*"; }
fail() { echo "  [FAIL] $*"; FAILED=$((FAILED + 1)); }

echo "==> Stopping kubelet on ${CP} (this stops the API server / scheduler / controller-manager / etcd static pods)..."
vagrant ssh "$CP" -c 'sudo systemctl stop kubelet' >/dev/null 2>&1 \
  || fail "could not stop kubelet on ${CP}"
sleep 20

echo
echo "==> API availability while the control plane is down"
if "${KUBE[@]}" get nodes >/dev/null 2>&1; then
  fail "API is still reachable (unexpected for a single control plane)"
else
  pass "kubectl can no longer reach the API server"
fi

echo
echo "==> Workloads keep running without the control plane"
if curl -fsS --max-time 5 http://localhost:18080/api/health >/dev/null 2>&1; then
  pass "chat application still serves traffic (http://localhost:18080/api/health)"
else
  fail "chat application did not answer on port 18080"
fi

echo
echo "==> Restoring the control plane"
vagrant ssh "$CP" -c 'sudo systemctl start kubelet' >/dev/null 2>&1 \
  || fail "could not restart kubelet on ${CP}"
restored=0
for _ in $(seq 1 60); do
  if "${KUBE[@]}" get nodes >/dev/null 2>&1; then
    restored=1
    break
  fi
  sleep 5
done
if [ "$restored" -eq 1 ]; then
  pass "API server is reachable again"
else
  fail "API server did not come back"
fi

"${KUBE[@]}" get nodes -o wide || true
"${KUBE[@]}" get pods -o wide || true

echo
if [ "$FAILED" -eq 0 ]; then
  echo "RESULT: expected single-control-plane behavior observed."
else
  echo "RESULT: $FAILED check(s) failed."
fi
echo "Evidence saved to: docs/evidence/kubeadm-controlplane-failure.txt"
exit "$FAILED"
