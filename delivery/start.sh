#!/usr/bin/env bash
set -euo pipefail

VM="CDA-Kubeadm-VM"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVA="$HERE/cda-kubeadm.ova"

find_vbox() {
  if [ -n "${VBOXMANAGE:-}" ]; then
    printf '%s\n' "$VBOXMANAGE"
    return 0
  fi
  if command -v VBoxManage >/dev/null 2>&1; then
    command -v VBoxManage
    return 0
  fi
  for p in /usr/bin/VBoxManage /usr/local/bin/VBoxManage /opt/VirtualBox/VBoxManage; do
    if [ -x "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

VBOX="$(find_vbox)" || {
  echo "ERROR: no se encontro VBoxManage. Instala VirtualBox o define VBOXMANAGE." >&2
  exit 1
}

port_busy() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

choose_port() {
  if [ -n "${APP_PORT:-}" ]; then
    PORT="$APP_PORT"
    return 0
  fi
  for p in 8080 8081 8082 8083 8084; do
    if ! port_busy "$p"; then
      PORT="$p"
      return 0
    fi
  done
  echo "ERROR: los puertos 8080-8084 estan ocupados. Define APP_PORT." >&2
  exit 1
}
choose_port

if ! "$VBOX" showvminfo "$VM" >/dev/null 2>&1; then
  echo "Importando $VM ..."
  "$VBOX" import "$OVA" --vsys 0 --vmname "$VM"
fi

STATE="$("$VBOX" showvminfo "$VM" --machinereadable 2>/dev/null || true)"
if ! grep -q 'VMState="running"' <<<"$STATE"; then
  "$VBOX" modifyvm "$VM" --natpf1 delete app >/dev/null 2>&1 || true
  "$VBOX" modifyvm "$VM" --natpf1 "app,tcp,127.0.0.1,$PORT,,30080"
  echo "Arrancando VM ..."
  if [ "${HEADLESS:-0}" = "1" ] || ! command -v xdg-open >/dev/null 2>&1; then
    "$VBOX" startvm "$VM" --type headless
  else
    "$VBOX" startvm "$VM" --type gui
  fi
fi

URL="http://127.0.0.1:$PORT/"
echo "Esperando $URL ..."

http_ok() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 "${URL}healthz" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O /dev/null -T 2 "${URL}healthz"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$URL" <<'PY' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen(sys.argv[1] + "healthz", timeout=2).read()
PY
  else
    return 1
  fi
}

for _ in $(seq 1 180); do
  if http_ok; then
    break
  fi
  sleep 2
done
if ! http_ok; then
  echo "ERROR: la VM arranco pero la app no responde." >&2
  exit 1
fi

echo "READY - $URL"
if [ -n "${BROWSER:-}" ]; then
  "$BROWSER" "$URL" >/dev/null 2>&1 &
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$URL" >/dev/null 2>&1 &
elif command -v gio >/dev/null 2>&1; then
  gio open "$URL" >/dev/null 2>&1 &
elif command -v sensible-browser >/dev/null 2>&1; then
  sensible-browser "$URL" >/dev/null 2>&1 &
fi
