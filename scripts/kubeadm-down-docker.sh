#!/usr/bin/env bash
set -euo pipefail

# Tear down only the experimental Docker-provider kubeadm lab.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export VAGRANT_VAGRANTFILE="$ROOT_DIR/Vagrantfile.kubeadm.docker"
export VAGRANT_DOTFILE_PATH="$ROOT_DIR/.vagrant-kubeadm-docker"

if ! command -v vagrant >/dev/null 2>&1; then
  echo "Error: 'vagrant' is required but not installed." >&2
  exit 1
fi

echo "==> Destroying kubeadm Docker containers..."
vagrant destroy -f

echo "==> Removing generated join data..."
rm -rf .kubeadm

echo "kubeadm Docker lab removed. k3d/k3s and the VirtualBox lab were not changed."
