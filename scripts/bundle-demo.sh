#!/usr/bin/env bash
set -euo pipefail

# Builds the self-contained demo bundle: minimal app image + manifests +
# scripts + a short README, packed as a single .zip ready to hand in.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC="$ROOT/demo-bundle"
OUT="${1:-$ROOT/cda-demo-bundle.zip}"
IMAGE="${IMAGE_NAME:-cda-demo:latest}"

if [ ! -d "$SRC" ]; then
  echo "No se encuentra $SRC" >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "Falta docker; no se puede construir la imagen." >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$SRC"/. "$STAGE"/
mkdir -p "$STAGE/images"

echo "==> Construyendo $IMAGE"
docker build -t "$IMAGE" "$SRC/app"

echo "==> Guardando imagen en images/cda-demo.tar"
docker save -o "$STAGE/images/cda-demo.tar" "$IMAGE"

# If k3d was already used on this machine, its k3s image can travel too so the
# other person does not need to download it.
K3S_IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' \
              | grep -E '^rancher/k3s:' | head -1 || true)"
if [ -n "$K3S_IMAGE" ]; then
  echo "==> Incluyendo $K3S_IMAGE en images/k3s.tar"
  docker save -o "$STAGE/images/k3s.tar" "$K3S_IMAGE"
  printf '%s\n' "$K3S_IMAGE" > "$STAGE/images/k3s-image.txt"
fi

echo "==> Creando ZIP: $OUT"
if command -v zip >/dev/null 2>&1; then
  (cd "$STAGE" && zip -q -r "$OUT" .)
elif command -v powershell.exe >/dev/null 2>&1; then
  WIN_TEMP="$(powershell.exe -NoProfile -Command '[System.IO.Path]::GetTempPath()' \
              | tr -d '\r')"
  WSL_TEMP="$(wslpath -u "$WIN_TEMP")"
  TMP_ZIP="$WSL_TEMP/cda-demo-bundle-$$.zip"

  PS1="$WSL_TEMP/cda-demo-zip-$$.ps1"
  cat > "$PS1" <<'PS'
param([string]$Source, [string]$Destination)
Compress-Archive -Path (Join-Path $Source '*') -DestinationPath $Destination -Force
PS

  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$PS1")" \
    -Source "$(wslpath -w "$STAGE")" -Destination "$(wslpath -w "$TMP_ZIP")"
  cp "$TMP_ZIP" "$OUT"
  rm -f "$TMP_ZIP" "$PS1"
else
  echo "Falta 'zip' y no hay powershell.exe; instala zip (apt install zip / pacman -S zip)." >&2
  exit 1
fi

echo "==> Listo"
ls -lh "$OUT"
