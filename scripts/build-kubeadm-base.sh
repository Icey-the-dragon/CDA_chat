#!/usr/bin/env bash
set -euo pipefail

# ONE-TIME builder of base/cda-kubeadm-base.vdi (and .zip + SHA256).
# Needs Vagrant + VirtualBox + Docker on this machine. The teacher machine does
# not need any of this: it uses scripts/kubeadm-vbox-lab.sh with the VDI.
#
#   bash scripts/build-kubeadm-base.sh
#
# The resulting files are binary deliverables, not Git files.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=scripts/virtualbox-preflight.sh
source "$ROOT_DIR/scripts/virtualbox-preflight.sh"
vbox_preflight "$ROOT_DIR" || exit 1

for cmd in vagrant docker VBoxManage tar zip sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 \
    || { echo "ERROR: '$cmd' is required to build the base VDI." >&2; exit 1; }
done

VM="cda-kubeadm-base"
OUT_DIR="$ROOT_DIR/base"
BASE_VDI="$OUT_DIR/${VM}.vdi"
OVA_FILE="$OUT_DIR/${VM}.ova"

mkdir -p "$OUT_DIR" "$ROOT_DIR/images"

echo "==> Building chat-server:latest on the builder host..."
docker build -t chat-server:latest src/chat-server
docker save -o images/chat-server.tar chat-server:latest

export VAGRANT_VAGRANTFILE="$ROOT_DIR/Vagrantfile.base"
export VAGRANT_DOTFILE_PATH="$ROOT_DIR/.vagrant-base"
export K8S_MINOR="${K8S_MINOR:-1.36}"

echo "==> Creating and provisioning the template VM..."
vagrant up "$VM"
vagrant halt "$VM"

echo "==> Exporting the template disk..."
rm -f "$OVA_FILE" "$BASE_VDI"
VBoxManage export "$VM" -o "$OVA_FILE"

# An OVA is a tar archive; the single .vdi inside is the template disk.
disk="$(tar -tf "$OVA_FILE" | grep -E '\.vdi$' | head -1)"
[ -n "$disk" ] || { echo "ERROR: no .vdi found in $OVA_FILE" >&2; exit 1; }
tar -xf "$OVA_FILE" -C "$OUT_DIR" "$disk"
extracted="$OUT_DIR/$disk"
[ "$extracted" != "$BASE_VDI" ] && mv "$extracted" "$BASE_VDI"
rm -f "$OVA_FILE"

echo "==> Compressing $BASE_VDI ..."
( cd "$OUT_DIR" && zip -j "${VM}.vdi.zip" "${VM}.vdi" )
( cd "$OUT_DIR" && sha256sum "${VM}.vdi" "${VM}.vdi.zip" > SHA256SUMS )

echo "==> Removing the builder VM (the VDI is already exported)..."
vagrant destroy -f "$VM"

cat <<EOF

Base image ready:

  ${BASE_VDI}
  ${BASE_VDI}.zip
  ${OUT_DIR}/SHA256SUMS

Copy base/ next to scripts/ on the teacher PC, or host the .zip and set
URL_BASE when running scripts/kubeadm-vbox-lab.sh.
EOF
