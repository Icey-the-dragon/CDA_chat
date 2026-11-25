#!/usr/bin/env bash
set -euo pipefail

# Build the single VM used to export ova/demo.ova. Not needed by the teacher.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=scripts/virtualbox-preflight.sh
source "$ROOT_DIR/scripts/virtualbox-preflight.sh"
if ! vbox_preflight "$ROOT_DIR"; then
  exit 1
fi

export VAGRANT_VAGRANTFILE="$ROOT_DIR/Vagrantfile.demo"
export VAGRANT_DOTFILE_PATH="$ROOT_DIR/.vagrant-demo"

command -v vagrant >/dev/null 2>&1 \
  || { echo "ERROR: vagrant is required to build the demo OVA." >&2; exit 1; }

vagrant up

echo
echo "Demo VM ready: http://localhost:8080/"
echo "Next: bash scripts/export-ova.sh demo"
