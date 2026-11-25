#!/usr/bin/env bash
set -euo pipefail

# Remove the local VM used to export ova/demo.ova. Not needed by the teacher.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export VAGRANT_VAGRANTFILE="$ROOT_DIR/Vagrantfile.demo"
export VAGRANT_DOTFILE_PATH="$ROOT_DIR/.vagrant-demo"

command -v vagrant >/dev/null 2>&1 \
  || { echo "ERROR: vagrant is required." >&2; exit 1; }

vagrant destroy -f
