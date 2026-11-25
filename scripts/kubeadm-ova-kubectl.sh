#!/usr/bin/env bash
set -uo pipefail

# Run kubectl on the control plane of an imported OVA cluster.
# No host kubectl, Vagrant or SSH client is needed: VirtualBox guestcontrol is
# used through scripts/ova-bin/vagrant.
#
#   bash scripts/kubeadm-ova-kubectl.sh get nodes -o wide
#   bash scripts/kubeadm-ova-kubectl.sh scale deployment/chat-server --replicas=4

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT_DIR/scripts/ova-bin:$PATH"

if [ "$#" -eq 0 ]; then
  echo "Usage: bash scripts/kubeadm-ova-kubectl.sh <kubectl args...>" >&2
  exit 1
fi

cmd="sudo kubectl"
for arg in "$@"; do
  printf -v escaped '%q' "$arg"
  cmd+=" $escaped"
done

exec vagrant ssh kubeadm-controlplane -c "$cmd"
