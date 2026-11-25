#!/usr/bin/env bash
# Shared preflight for scripts that start VirtualBox VMs.
# Source it, then call `vbox_preflight "$ROOT_DIR"`.
#
# On Linux, VirtualBox cannot start a VM while the native KVM modules are
# loaded. Vagrant shows "VBoxManage is blocked by another hypervisor". This
# helper unloads them when passwordless sudo is available; otherwise it prints
# the exact command to run.

_vbox_kvm_modules() {
  lsmod 2>/dev/null \
    | awk '$1 ~ /^kvm(_intel|_amd)?$/ { print $1 }' \
    | sort -u
}

vbox_preflight() {
  local root_dir="${1:-}" modules m
  if ! command -v VBoxManage >/dev/null 2>&1; then
    echo "ERROR: VBoxManage is not in PATH. Install VirtualBox (and add your user to vboxusers)." >&2
    return 1
  fi

  [ "$(uname -s)" = Linux ] || return 0

  modules="$(_vbox_kvm_modules)"
  [ -z "$modules" ] && return 0

  echo "==> KVM modules are loaded and block VirtualBox: $(echo "$modules" | tr '\n' ' ')"

  # Set VBOX_KVM_UNLOAD=0 if you do not want this script to touch kvm_intel /
  # kvm_amd / kvm. VirtualBox itself still needs them unloaded to start a VM.
  if [ "${VBOX_KVM_UNLOAD:-1}" = 0 ]; then
    cat >&2 <<EOF
WARNING: VBOX_KVM_UNLOAD=0, leaving the modules loaded. VirtualBox will fail
with "VT-x is not available" until you run:

  sudo modprobe -r kvm_intel kvm_amd kvm
EOF
    return 0
  fi

  if ! sudo -n true 2>/dev/null; then
    cat >&2 <<EOF
ERROR: unload them before running Vagrant:

  sudo modprobe -r kvm_intel kvm_amd kvm

Use only the module names that exist on this machine. To avoid the problem
after a reboot, blacklist them:

  printf 'blacklist kvm\\nblacklist kvm_intel\\nblacklist kvm_amd\\n' | sudo tee /etc/modprobe.d/blacklist-kvm.conf

Do not run the Vagrant scripts with sudo.
EOF
    return 1
  fi

  echo "==> Unloading KVM modules (passwordless sudo available)..."
  # Order matters: vendor modules must go before the generic kvm module.
  for m in kvm_intel kvm_amd kvm; do
    if printf '%s\n' "$modules" | grep -qx "$m"; then
      echo "    sudo modprobe -r $m"
      sudo modprobe -r "$m" >/dev/null 2>&1 || true
    fi
  done

  modules="$(_vbox_kvm_modules)"
  if [ -n "$modules" ]; then
    echo "ERROR: these modules are still loaded: $(echo "$modules" | tr '\n' ' ')" >&2
    return 1
  fi
  echo "==> VirtualBox can start VMs now."

  # Keep the argument for callers that pass ROOT_DIR even when unused.
  : "$root_dir"
  return 0
}
