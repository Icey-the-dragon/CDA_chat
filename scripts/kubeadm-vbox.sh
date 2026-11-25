#!/usr/bin/env bash
set -uo pipefail

# Run the whole kubeadm lab with VBoxManage only: no Vagrant binary, no Docker,
# no host kubectl and no SSH client. The three exported OVAs must be in ova/.
#
#   bash scripts/kubeadm-vbox.sh            # import + start + verify + chaos + master failure
#   bash scripts/kubeadm-vbox.sh start      # only import/start and wait for the app
#   bash scripts/kubeadm-vbox.sh verify     # start + verification
#   bash scripts/kubeadm-vbox.sh chaos      # start + 11 fault scenarios
#   bash scripts/kubeadm-vbox.sh failure    # start + control-plane failure test
#   bash scripts/kubeadm-vbox.sh stop
#   bash scripts/kubeadm-vbox.sh reset      # delete the VMs and reimport from OVA
#
# NOTE: this does not avoid the KVM conflict. VirtualBox itself (not Vagrant)
# cannot start a VM while kvm_intel/kvm_amd is loaded. The shared preflight
# unloads it when possible; VBOX_KVM_UNLOAD=0 leaves it untouched but then
# VBoxManage startvm will fail with "VT-x is not available".

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=scripts/virtualbox-preflight.sh
source "$ROOT_DIR/scripts/virtualbox-preflight.sh"

usage() {
  cat <<'EOF'
Usage: bash scripts/kubeadm-vbox.sh [all|start|stop|reset|verify|chaos|failure]

  all      import/start the 3 OVAs, then run verify + chaos + master failure
  start    only import/start and wait for the app
  verify   start, then run the full verification
  chaos    start, then run the 11 fault scenarios
  failure  start, then run the control-plane failure test
  stop     power off the VMs
  reset    delete the VMs and reimport them from ova/

Needs only VirtualBox + curl. The OVA files must be in ova/ (or OVA_DIR).
EOF
}

ACTION="${1:-all}"
case "$ACTION" in
  all|start|stop|reset|verify|chaos|failure) ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; exit 1 ;;
esac

for cmd in VBoxManage curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '$cmd' is required (install VirtualBox and curl)." >&2
    exit 1
  fi
done

if [ "$ACTION" != stop ] && ! vbox_preflight "$ROOT_DIR"; then
  exit 1
fi

# Do not open one browser window per test script.
export NO_OPEN="${NO_OPEN:-1}"
export VBOX_TYPE="${VBOX_TYPE:-headless}"

run() {
  echo
  echo "==> $*"
  bash "$@" || exit $?
}

start_cluster() {
  local open="${1:-0}"
  NO_OPEN="$open" run "$ROOT_DIR/scripts/launch-ova.sh" kubeadm start
}

case "$ACTION" in
  stop|reset)
    run "$ROOT_DIR/scripts/launch-ova.sh" kubeadm "$ACTION"
    exit 0
    ;;
  start)
    start_cluster 0
    exit 0
    ;;
  verify)
    start_cluster
    run "$ROOT_DIR/scripts/kubeadm-verify-ova.sh"
    exit 0
    ;;
  chaos)
    start_cluster
    run "$ROOT_DIR/scripts/kubeadm-chaos-ova.sh"
    exit 0
    ;;
  failure)
    start_cluster
    run "$ROOT_DIR/scripts/kubeadm-controlplane-failure-ova.sh"
    exit 0
    ;;
esac

# all: import/start once, then run every automated test.
echo "============================================================"
echo " kubeadm lab - VBoxManage only (no Vagrant binary)"
echo "============================================================"
start_cluster

run "$ROOT_DIR/scripts/kubeadm-verify-ova.sh"
run "$ROOT_DIR/scripts/kubeadm-chaos-ova.sh"
run "$ROOT_DIR/scripts/kubeadm-controlplane-failure-ova.sh"

echo
echo "ALL DONE. Evidence: docs/evidence/"
echo "  kubeadm-verify.txt"
echo "  kubeadm-chaos.txt"
echo "  kubeadm-controlplane-failure.txt"
echo "Chat UI: http://127.0.0.1:18080/  (also :18081 and :18082)"
