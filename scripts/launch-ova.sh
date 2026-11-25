#!/usr/bin/env bash
set -uo pipefail

# One-script delivery for a teacher machine that only needs VirtualBox + curl.
#
#   bash scripts/launch-ova.sh demo              # demo-bundle VM  -> :8080
#   bash scripts/launch-ova.sh kubeadm           # 3-node kubeadm  -> :18080/:18081
#   bash scripts/launch-ova.sh kubeadm stop      # power off
#   bash scripts/launch-ova.sh kubeadm reset     # delete + reimport + start
#
# The .ova files are not in Git (too big). Put them in ova/ or set OVA_DIR.
# See docs/OVA_DELIVERY.md for the export/prepare steps.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=scripts/virtualbox-preflight.sh
source "$ROOT_DIR/scripts/virtualbox-preflight.sh"

usage() {
  cat <<EOF
Usage: bash scripts/launch-ova.sh <demo|kubeadm> [start|stop|reset|verify]

  start   import (if needed), configure NAT port forwards, boot and wait
  stop    power off the VMs
  reset   unregister + delete the VMs, then start again from the OVAs
  verify  start, then run kubeadm-verify-ova.sh (kubeadm only)

Environment overrides:
  OVA_DIR        directory with the .ova files (default: $ROOT_DIR/ova)
  VBOX_TYPE      headless (default) or gui
  NO_OPEN=1      do not open the browser automatically
  SSH_PF=1       also publish SSH on 127.0.0.1:2201-2203 (kubeadm only)
  WAIT_SECONDS   app readiness timeout (default: 420)
EOF
}

MODE="${1:-}"
ACTION="${2:-start}"
case "$MODE" in
  demo|kubeadm) ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; exit 1 ;;
esac
case "$ACTION" in
  start|stop|reset|verify) ;;
  *) usage >&2; exit 1 ;;
esac
if [ "$ACTION" = verify ] && [ "$MODE" != kubeadm ]; then
  echo "ERROR: verify is only available for the kubeadm OVA." >&2
  exit 1
fi

for cmd in VBoxManage curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '$cmd' is required on the host (install VirtualBox and curl)." >&2
    exit 1
  fi
done

if [ "$ACTION" != stop ] && ! vbox_preflight "$ROOT_DIR"; then
  exit 1
fi

OVA_DIR="${OVA_DIR:-$ROOT_DIR/ova}"
LOG_DIR="$ROOT_DIR/docs/evidence"
mkdir -p "$LOG_DIR"
exec > >(tee "$LOG_DIR/ova-launch-${MODE}.txt") 2>&1

HOSTONLY_NET="${HOSTONLY_NET:-vboxnet0}"
HOSTONLY_IP="${HOSTONLY_IP:-192.168.56.1}"
HOSTONLY_MASK="${HOSTONLY_MASK:-255.255.255.0}"

if [ "$MODE" = demo ]; then
  VM_NAMES=(cda-demo-vm)
  OVA_PATHS=("$OVA_DIR/demo.ova")
  APP_URLS=(http://127.0.0.1:8080/healthz)
  UI_URL=http://127.0.0.1:8080/
else
  VM_NAMES=(kubeadm-controlplane kubeadm-worker-infra kubeadm-worker-app)
  OVA_PATHS=(
    "$OVA_DIR/kubeadm-controlplane.ova"
    "$OVA_DIR/kubeadm-worker-infra.ova"
    "$OVA_DIR/kubeadm-worker-app.ova"
  )
  # 18080/18081 are the two worker NodePorts. 18082 is the control-plane
  # NodePort; it is useful to prove the app still works when a worker is off.
  APP_URLS=(
    http://127.0.0.1:18080/api/health
    http://127.0.0.1:18081/api/health
    http://127.0.0.1:18082/api/health
  )
  UI_URL=http://127.0.0.1:18080/
fi

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_ovas() {
  local ova
  for ova in "${OVA_PATHS[@]}"; do
    [ -f "$ova" ] || die "missing OVA: ${ova}
Copy the OVA files into ${OVA_DIR} (see docs/OVA_DELIVERY.md)."
  done
}

vm_exists() {
  VBoxManage list vms | grep -q "\"$1\""
}

vm_running() {
  VBoxManage showvminfo "$1" --machinereadable 2>/dev/null \
    | grep -q '^VMState="running"'
}

hostonly_ip() {
  VBoxManage list hostonlyifs \
    | awk -v name="$HOSTONLY_NET" '
        $0 ~ "^Name: +" name "[[:space:]]*$" { found = 1; next }
        found && /^IPAddress:/ { print $2; exit }
      '
}

ensure_hostonly() {
  if ! VBoxManage list hostonlyifs \
      | grep -qE "^Name: +${HOSTONLY_NET}[[:space:]]*$"; then
    echo "==> Creating VirtualBox host-only adapter ${HOSTONLY_NET}..."
    VBoxManage hostonlyif create >/dev/null \
      || die "could not create host-only adapter ${HOSTONLY_NET}"
  fi

  local ip
  ip="$(hostonly_ip)"
  if [ -z "$ip" ]; then
    echo "==> Assigning ${HOSTONLY_IP}/${HOSTONLY_MASK} to ${HOSTONLY_NET}..."
    VBoxManage hostonlyif ipconfig "$HOSTONLY_NET" \
      --ip "$HOSTONLY_IP" --netmask "$HOSTONLY_MASK" >/dev/null \
      || die "could not configure ${HOSTONLY_NET} with ${HOSTONLY_IP}"
    ip="$(hostonly_ip)"
  fi
  if [ "$ip" != "$HOSTONLY_IP" ]; then
    die "${HOSTONLY_NET} has IP '${ip}', expected ${HOSTONLY_IP}.
The exported kubeadm nodes use static IPs 192.168.56.20-22. Choose another
adapter with HOSTONLY_NET=vboxnetN, or free this one and set its IP to
${HOSTONLY_IP}."
  fi

  # Static guest IPs are baked into the OVAs; a host-only DHCP server is not
  # needed and can overwrite them on some VirtualBox versions.
  VBoxManage dhcpserver remove --ifname "$HOSTONLY_NET" >/dev/null 2>&1 || true
}

clear_nat_rules() {
  local vm="$1" rule
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    VBoxManage modifyvm "$vm" --natpf1 delete "$rule" >/dev/null 2>&1 || true
  done < <(VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null \
    | sed -n 's/^NATRule[0-9][0-9]*="\([^,]*\),.*/\1/p')
}

set_pf() {
  local vm="$1" rule="$2" host_port="$3" guest_port="$4"
  VBoxManage modifyvm "$vm" --natpf1 delete "$rule" >/dev/null 2>&1 || true
  VBoxManage modifyvm "$vm" \
    --natpf1 "${rule},tcp,127.0.0.1,${host_port},,${guest_port}" \
    || die "could not create port-forward ${host_port} -> ${guest_port} on ${vm}"
}

configure_vm() {
  local vm="$1" ova="$2" i

  if vm_exists "$vm"; then
    echo "==> VM '${vm}' already registered; reusing it"
  else
    echo "==> Importing ${ova} as '${vm}'..."
    VBoxManage import "$ova" --vsys 0 --vmname "$vm" \
      || die "VBoxManage import failed for ${ova}"
  fi

  # Adapter 1 is NAT. Remove stale/Vagrant forwards, then add our own below.
  # Regenerate MACs so two copies of the same OVA cannot clash on the LAN.
  clear_nat_rules "$vm"
  VBoxManage modifyvm "$vm" --nic1 nat
  for i in 1 2; do
    VBoxManage modifyvm "$vm" --macaddress"$i" auto >/dev/null 2>&1 || true
  done

  if [ "$MODE" = kubeadm ]; then
    # Adapter 2 is the private cluster LAN with the static node IPs.
    VBoxManage modifyvm "$vm" --nic2 hostonly --hostonlyadapter2 "$HOSTONLY_NET" \
      || die "could not attach ${vm} to ${HOSTONLY_NET}"
  fi
}

configure_ports() {
  local vm="$1"
  case "$vm" in
    cda-demo-vm)
      set_pf "$vm" demo 8080 8080
      ;;
    kubeadm-controlplane)
      set_pf "$vm" chat-cp 18082 30080
      ;;
    kubeadm-worker-infra)
      set_pf "$vm" chat-infra 18080 30080
      ;;
    kubeadm-worker-app)
      set_pf "$vm" chat-app 18081 30080
      ;;
  esac

  if [ "$MODE" = kubeadm ] && [ "${SSH_PF:-0}" = 1 ]; then
    case "$vm" in
      kubeadm-controlplane)   set_pf "$vm" ssh 2201 22 ;;
      kubeadm-worker-infra)   set_pf "$vm" ssh 2202 22 ;;
      kubeadm-worker-app)     set_pf "$vm" ssh 2203 22 ;;
    esac
  fi
}

stop_vms() {
  local i vm
  for ((i = ${#VM_NAMES[@]} - 1; i >= 0; i--)); do
    vm="${VM_NAMES[$i]}"
    if vm_exists "$vm" && vm_running "$vm"; then
      echo "==> Powering off '${vm}'..."
      VBoxManage controlvm "$vm" acpipowerbutton >/dev/null 2>&1 || \
        VBoxManage controlvm "$vm" poweroff >/dev/null 2>&1 || true
    fi
  done
}

reset_vms() {
  local vm
  stop_vms
  for vm in "${VM_NAMES[@]}"; do
    if vm_exists "$vm"; then
      echo "==> Deleting old VM '${vm}'..."
      VBoxManage unregistervm "$vm" --delete >/dev/null \
        || die "could not delete ${vm}"
    fi
  done
}

wait_any_url() {
  local timeout="$1" url elapsed=0
  shift
  while [ "$elapsed" -lt "$timeout" ]; do
    for url in "$@"; do
      if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
        WORKING_URL="$url"
        echo "  [wait] ${url}: OK after ${elapsed}s"
        return 0
      fi
    done
    sleep 3
    elapsed=$((elapsed + 3))
  done
  echo "  [wait] timeout after ${timeout}s; tried: $*"
  return 1
}

open_url() {
  local url="$1"
  [ "${NO_OPEN:-0}" = 1 ] && return 0
  case "$(uname -s)" in
    Linux)
      if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 &
      fi
      ;;
    Darwin)
      if command -v open >/dev/null 2>&1; then
        open "$url" >/dev/null 2>&1 &
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      if command -v start >/dev/null 2>&1; then
        start "" "$url" >/dev/null 2>&1 &
      fi
      ;;
  esac
}

echo "============================================================"
echo " VirtualBox OVA launcher - ${MODE} ${ACTION}"
echo " OVA directory: ${OVA_DIR}"
echo "============================================================"

if [ "$ACTION" = stop ]; then
  stop_vms
  echo "Done."
  exit 0
fi

require_ovas

if [ "$ACTION" = reset ]; then
  reset_vms
fi

if [ "$MODE" = kubeadm ]; then
  ensure_hostonly
fi

for i in "${!VM_NAMES[@]}"; do
  configure_vm "${VM_NAMES[$i]}" "${OVA_PATHS[$i]}"
  configure_ports "${VM_NAMES[$i]}"
done

echo
echo "==> Starting VMs (${VBOX_TYPE:-headless})..."
for vm in "${VM_NAMES[@]}"; do
  if vm_running "$vm"; then
    echo "  ${vm}: already running"
  else
    VBoxManage startvm "$vm" --type "${VBOX_TYPE:-headless}" \
      || die "could not start ${vm}"
  fi
done

echo
echo "==> Waiting for the application..."
WORKING_URL=""
if ! wait_any_url "${WAIT_SECONDS:-420}" "${APP_URLS[@]}"; then
  echo
  echo "The VMs started but the app did not answer yet. Check with:"
  for vm in "${VM_NAMES[@]}"; do
    echo "  VBoxManage showvminfo '${vm}' | grep State"
  done
  exit 1
fi

if [ "$MODE" = kubeadm ]; then
  case "$WORKING_URL" in
    *18081*) UI_URL=http://127.0.0.1:18081/ ;;
    *18082*) UI_URL=http://127.0.0.1:18082/ ;;
    *)       UI_URL=http://127.0.0.1:18080/ ;;
  esac
fi

echo
echo "============================================================"
echo " READY: ${WORKING_URL}"
echo " UI:    ${UI_URL}"
if [ "$MODE" = kubeadm ]; then
  echo " Chat:     http://127.0.0.1:18080/  (infra worker)"
  echo "           http://127.0.0.1:18081/  (app worker)"
  echo "           http://127.0.0.1:18082/  (control plane)"
  echo " Grafana:  http://127.0.0.1:18080/grafana/"
fi
echo " Log:   ${LOG_DIR}/ova-launch-${MODE}.txt"
echo " Stop:  bash scripts/launch-ova.sh ${MODE} stop"
echo "============================================================"

open_url "$UI_URL"

if [ "$ACTION" = verify ]; then
  echo
  echo "==> Running kubeadm verification inside the imported cluster..."
  bash "$ROOT_DIR/scripts/kubeadm-verify-ova.sh" || exit $?
fi
