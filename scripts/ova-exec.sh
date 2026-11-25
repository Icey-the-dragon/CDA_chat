#!/usr/bin/env bash
set -uo pipefail

# Run a command inside an imported OVA VM through VirtualBox guestcontrol.
# This avoids needing Vagrant, SSH or a host kubectl on the teacher machine.
#
#   bash scripts/ova-exec.sh cda-demo-vm 'cd /opt/demo-bundle && bash bench.sh'
#   bash scripts/ova-exec.sh kubeadm-controlplane 'sudo kubectl get pods -o wide'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT_DIR/scripts/ova-bin:$PATH"

if [ "$#" -lt 2 ]; then
  echo "Usage: bash scripts/ova-exec.sh <vm-name> '<shell command>'" >&2
  exit 1
fi

exec vagrant ssh "$1" -c "$2"
