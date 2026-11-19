#!/usr/bin/env bash
set -euo pipefail

# Wrapper: run the control-plane failure test against the Docker variant.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export VAGRANT_VAGRANTFILE="$ROOT_DIR/Vagrantfile.kubeadm.docker"
export VAGRANT_DOTFILE_PATH="$ROOT_DIR/.vagrant-kubeadm-docker"
export KUBEADM_PREFIX="kubeadm-docker"

exec bash "$ROOT_DIR/scripts/kubeadm-controlplane-failure.sh" "$@"
