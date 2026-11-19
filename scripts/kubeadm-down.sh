#!/usr/bin/env bash
set -euo pipefail

# Tear down only the parallel kubeadm lab. The k3d/k3s setups are untouched.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export VAGRANT_VAGRANTFILE="$ROOT_DIR/Vagrantfile.kubeadm"
export VAGRANT_DOTFILE_PATH="$ROOT_DIR/.vagrant-kubeadm"

if ! command -v vagrant >/dev/null 2>&1; then
  echo "Error: 'vagrant' is required but not installed." >&2
  exit 1
fi

echo "==> Destroying kubeadm lab VMs..."
vagrant destroy -f

echo "==> Removing generated kubeadm credentials/join data..."
rm -rf .kubeadm

echo "kubeadm lab removed. The k3d/k3s setup was not changed."
