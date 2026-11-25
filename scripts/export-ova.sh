#!/usr/bin/env bash
set -euo pipefail

# Export an already-provisioned lab as OVA files for scripts/launch-ova.sh.
#
#   bash scripts/demo-ova-up.sh      # build the single demo VM
#   bash scripts/export-ova.sh demo  # -> ova/demo.ova
#
#   bash scripts/kubeadm-up.sh       # build the 3-node kubeadm lab
#   bash scripts/export-ova.sh kubeadm
#
# The VMs are powered off before export so etcd/containerd write consistent
# disks. This script needs VBoxManage on the machine that BUILT the lab, not
# on the teacher machine.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<EOF
Usage: bash scripts/export-ova.sh <demo|kubeadm>

Environment overrides:
  OVA_DIR   output directory (default: $ROOT_DIR/ova)
EOF
}

MODE="${1:-}"
case "$MODE" in
  demo|kubeadm) ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; exit 1 ;;
esac

command -v VBoxManage >/dev/null 2>&1 \
  || { echo "ERROR: VBoxManage is required to export OVAs." >&2; exit 1; }

OVA_DIR="${OVA_DIR:-$ROOT_DIR/ova}"
mkdir -p "$OVA_DIR"

if [ "$MODE" = demo ]; then
  VM_NAMES=(cda-demo-vm)
  OVA_NAMES=(demo.ova)
else
  VM_NAMES=(kubeadm-controlplane kubeadm-worker-infra kubeadm-worker-app)
  OVA_NAMES=(kubeadm-controlplane.ova kubeadm-worker-infra.ova kubeadm-worker-app.ova)
fi

vm_state() {
  VBoxManage showvminfo "$1" --machinereadable 2>/dev/null \
    | sed -n 's/^VMState="\([^"]*\)"$/\1/p'
}

poweroff_vm() {
  local vm="$1" state _ i
  state="$(vm_state "$vm")"
  [ -n "$state" ] || return 0
  [ "$state" = poweroff ] && return 0

  echo "==> Stopping '${vm}' (state: ${state}) for a clean snapshot..."
  VBoxManage controlvm "$vm" acpipowerbutton >/dev/null 2>&1 || true
  for i in $(seq 1 30); do
    [ "$(vm_state "$vm")" = poweroff ] && return 0
    sleep 2
  done
  VBoxManage controlvm "$vm" poweroff >/dev/null 2>&1 || true
  for i in $(seq 1 15); do
    [ "$(vm_state "$vm")" = poweroff ] && return 0
    sleep 1
  done
  echo "WARNING: '${vm}' is still '$(vm_state "$vm")'; exporting anyway." >&2
}

EXTRA_EXPORT_ARGS=()
if VBoxManage export --help 2>&1 | grep -q -- '--ovf20'; then
  EXTRA_EXPORT_ARGS+=(--ovf20)
fi

# Stop workers before the control plane so kubelet/etcd shut down gracefully.
for ((i = ${#VM_NAMES[@]} - 1; i >= 0; i--)); do
  vm="${VM_NAMES[$i]}"
  VBoxManage showvminfo "$vm" >/dev/null 2>&1 \
    || { echo "ERROR: VM '$vm' does not exist. Build the lab first." >&2; exit 1; }
  poweroff_vm "$vm"
done

echo "==> Exporting OVAs into ${OVA_DIR}..."
for i in "${!VM_NAMES[@]}"; do
  vm="${VM_NAMES[$i]}"
  out="${OVA_DIR}/${OVA_NAMES[$i]}"
  rm -f "$out" "${out%.ova}.mf"
  echo "  ${vm} -> ${out}"
  VBoxManage export "$vm" --output "$out" "${EXTRA_EXPORT_ARGS[@]}" \
    || { echo "ERROR: VBoxManage export failed for ${vm}." >&2; exit 1; }
done

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$OVA_DIR" && sha256sum "${OVA_NAMES[@]}" > SHA256SUMS)
  echo "==> Wrote ${OVA_DIR}/SHA256SUMS"
fi

cat > "$OVA_DIR/README.txt" <<EOF
OVA delivery bundle - ${MODE}

Files:
$(printf '  %s\n' "${OVA_NAMES[@]}")

On the teacher machine (VirtualBox + curl only):
  bash scripts/launch-ova.sh ${MODE}

The launcher imports any missing VM, replaces stale NAT rules with the
required port forwards, boots everything and waits for the app.
Do not run 'vagrant up' on the teacher machine.
EOF

echo
echo "Done. Copy this directory to the teacher machine and run:"
echo "  bash scripts/launch-ova.sh ${MODE}"
