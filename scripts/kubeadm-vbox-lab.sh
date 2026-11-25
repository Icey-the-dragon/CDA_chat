#!/bin/bash

# Descripcion
TITULO="CDA Chat - kubeadm (1 control-plane + 2 workers)"
CURSO="Centros de Datos, 2026/27"
DIR_BASE_POR_DEFECTO=$HOME/CDA2627
DIR_BASE=${DIR_BASE:-$DIR_BASE_POR_DEFECTO}
DIR_VARLIB=${DIR_VARLIB:-/var/lib/CDA2627}
URL_BASE=${URL_BASE:-}

# Base generada una sola vez con scripts/build-kubeadm-base.sh.
# El PC del profesor NO necesita Vagrant, Docker, kubectl ni SSH: solo
# VirtualBox, curl/unzip/wget y esta base VDI.
#
#   bash scripts/kubeadm-vbox-lab.sh          # crear (si falta) y arrancar
#   SKIP_INIT=1 bash scripts/kubeadm-vbox-lab.sh   # solo crear y arrancar
#   bash scripts/kubeadm-vbox-lab.sh stop
#   bash scripts/kubeadm-vbox-lab.sh reset
#
# Las VM son idempotentes: si el directorio $DIR_BASE/$MV ya existe, no se
# vuelven a crear (igual que el script del profe). Se arrancan en cada
# ejecucion. Despues se configura kubeadm mediante VBoxManage guestcontrol.

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

NOMBRE_BASE=cda-kubeadm-base
HOSTONLY_NET=${HOSTONLY_NET:-vboxnet0}
HOSTONLY_IP=${HOSTONLY_IP:-192.168.56.1}
HOSTONLY_MASK=${HOSTONLY_MASK:-255.255.255.0}
VBOX_TYPE=${VBOX_TYPE:-headless}
ACCION=${1:-start}

# ---------------------------------------------------------------------------
# Funciones de apoyo (mismo estilo que el script del profe)
# ---------------------------------------------------------------------------

preparar_imagen() {
  local nombre=$1 destino=$2 url=$3
  local zip="$destino/$nombre.vdi.zip"

  [ -e "$destino/$nombre.vdi" ] && return 0

  if [ ! -e "$zip" ]; then
    if [ -z "$url" ]; then
      echo "ERROR: falta $destino/$nombre.vdi y no se ha definido URL_BASE." >&2
      echo "       Genera la base con: bash scripts/build-kubeadm-base.sh" >&2
      return 1
    fi
    echo "Descargando imagen $url/$nombre.vdi.zip ..."
    ( cd "$destino" && wget --continue "$url/$nombre.vdi.zip" ) || return 1
  fi

  echo "Descomprimiendo imagen $destino/$nombre.vdi ..."
  ( cd "$destino" && unzip -o "$nombre.vdi.zip" ) || return 1
  rm -f "$zip"
}

vm_existe() {
  [ -e "$DIR_BASE/$1" ] || VBoxManage list vms | grep -q "\"$1\""
}

vm_arrancada() {
  VBoxManage showvminfo "$1" --machinereadable 2>/dev/null \
    | grep -q '^VMState="running"'
}

asegurar_hostonly() {
  if ! VBoxManage list hostonlyifs \
      | grep -qE "^Name: +${HOSTONLY_NET}[[:space:]]*$"; then
    echo "==> Creando adaptador host-only ..."
    VBoxManage hostonlyif create >/dev/null || return 1
    # VirtualBox elige el primer nombre libre (vboxnet0, vboxnet1, ...).
    HOSTONLY_NET=$(VBoxManage list hostonlyifs | awk '/^Name:/ {n=$2} END {print n}')
    echo "    Usando ${HOSTONLY_NET}"
  fi

  local ip
  ip=$(VBoxManage list hostonlyifs | awk -v n="$HOSTONLY_NET" '
    $0 ~ "^Name: +" n "[[:space:]]*$" { f=1; next }
    f && /^IPAddress:/ { print $2; exit }')
  if [ -z "$ip" ]; then
    echo "==> Asignando ${HOSTONLY_IP}/${HOSTONLY_MASK} a ${HOSTONLY_NET} ..."
    VBoxManage hostonlyif ipconfig "$HOSTONLY_NET" \
      --ip "$HOSTONLY_IP" --netmask "$HOSTONLY_MASK" >/dev/null || return 1
    ip=$(VBoxManage list hostonlyifs | awk -v n="$HOSTONLY_NET" '
      $0 ~ "^Name: +" n "[[:space:]]*$" { f=1; next }
      f && /^IPAddress:/ { print $2; exit }')
  fi
  if [ "$ip" != "$HOSTONLY_IP" ]; then
    echo "ERROR: ${HOSTONLY_NET} tiene IP '$ip', esperada ${HOSTONLY_IP}." >&2
    echo "       Usa HOSTONLY_NET=vboxnet1 o libera ese adaptador." >&2
    return 1
  fi
  VBoxManage dhcpserver remove --ifname "$HOSTONLY_NET" >/dev/null 2>&1 || true
}

crear_vm() {
  local MV=$1 IP=$2 MAC1=$3 MAC2=$4 PUERTO=$5 ROLE=$6
  local VDI="$DIR_BASE/$MV.vdi"

  [ -e "$DIR_BASE/$MV" ] && { echo "  $MV: ya existe, no se recrea"; return 0; }

  echo "  Creando $MV ($ROLE, $IP, host $PUERTO) ..."
  VBoxManage createvm --name "$MV" --basefolder "$DIR_BASE" \
    --ostype Debian_64 --register >/dev/null || return 1
  VBoxManage storagectl "$MV" --name "${MV}_storage" --add sata --portcount 4 >/dev/null

  # Copia privada de la base: cada nodo tiene su propio /etc/kubernetes,
  # machine-id y containerd (multiattach no vale para kubeadm).
  cp "$BASE_VDI" "$VDI" || return 1
  VBoxManage storageattach "$MV" --storagectl "${MV}_storage" \
    --port 0 --device 0 --type hdd --medium "$VDI" || return 1

  VBoxManage modifyvm "$MV" --cpus 2 --memory 2048 --vram 16 \
    --graphicscontroller vmsvga --pae on >/dev/null
  VBoxManage modifyvm "$MV" --nic1 hostonly --hostonlyadapter1 "$HOSTONLY_NET" \
    --macaddress1 "$MAC1" --cableconnected1 on --nictype1 82540EM >/dev/null
  VBoxManage modifyvm "$MV" --nic2 nat \
    --macaddress2 "$MAC2" --cableconnected2 on --nictype2 82540EM >/dev/null
  VBoxManage modifyvm "$MV" --natpf2 "chat,tcp,127.0.0.1,${PUERTO},,30080" >/dev/null

  VBoxManage guestproperty set "$MV" /CDA/role "$ROLE" >/dev/null
  VBoxManage guestproperty set "$MV" /CDA/hostname "$MV" >/dev/null
  VBoxManage guestproperty set "$MV" /CDA/eth0/address "$IP" >/dev/null
  VBoxManage guestproperty set "$MV" /CDA/eth0/netmask 24 >/dev/null
  VBoxManage guestproperty set "$MV" /CDA/eth1/address 10.0.2.15 >/dev/null
  VBoxManage guestproperty set "$MV" /CDA/default_gateway 10.0.2.2 >/dev/null
  VBoxManage guestproperty set "$MV" /CDA/default_nameserver 8.8.8.8 >/dev/null
  VBoxManage guestproperty set "$MV" /CDA/etc_hosts_dump \
    "kubeadm-controlplane:192.168.56.20,kubeadm-worker-infra:192.168.56.21,kubeadm-worker-app:192.168.56.22" >/dev/null
}

parar_vms() {
  local MV
  for MV in "${MVS[@]}"; do
    vm_existe "$MV" && vm_arrancada "$MV" && {
      echo "  Apagando $MV ..."
      VBoxManage controlvm "$MV" acpipowerbutton >/dev/null 2>&1 || \
        VBoxManage controlvm "$MV" poweroff >/dev/null 2>&1 || true
    }
  done
}

borrar_vms() {
  local MV
  parar_vms
  for MV in "${MVS[@]}"; do
    if vm_existe "$MV"; then
      echo "  Borrando $MV ..."
      VBoxManage unregistervm "$MV" --delete >/dev/null || return 1
    fi
  done
}

# ---------------------------------------------------------------------------

MV_CP=kubeadm-controlplane
MV_INFRA=kubeadm-worker-infra
MV_APP=kubeadm-worker-app
MVS=("$MV_CP" "$MV_INFRA" "$MV_APP")

case "$ACCION" in
  stop)   parar_vms; echo "Done."; exit 0 ;;
  reset)  borrar_vms || exit 1 ;;
  start)  ;;
  *) echo "Usage: bash scripts/kubeadm-vbox-lab.sh [start|stop|reset]" >&2; exit 1 ;;
esac

for cmd in VBoxManage wget unzip curl; do
  command -v "$cmd" >/dev/null 2>&1 \
    || { echo "ERROR: falta '$cmd' en el host." >&2; exit 1; }
done

mkdir -p "$DIR_BASE"

BASE_VDI=
for candidato in \
  "$DIR_VARLIB/$NOMBRE_BASE.vdi" \
  "$DIR_BASE/$NOMBRE_BASE.vdi" \
  "$ROOT_DIR/base/$NOMBRE_BASE.vdi"; do
  if [ -e "$candidato" ]; then BASE_VDI=$(realpath -m "$candidato"); break; fi
done
if [ -z "$BASE_VDI" ]; then
  [ -e "$DIR_VARLIB" ] || mkdir -p "$DIR_VARLIB" 2>/dev/null || DIR_VARLIB="$DIR_BASE"
  preparar_imagen "$NOMBRE_BASE" "$DIR_VARLIB" "$URL_BASE" || exit 1
  BASE_VDI=$(realpath -m "$DIR_VARLIB/$NOMBRE_BASE.vdi")
fi
echo "Base VDI: $BASE_VDI"

asegurar_hostonly || exit 1

echo "==> Creando las VM (solo la primera vez) ..."
crear_vm "$MV_CP"   192.168.56.20 080027111120 080027111130 18082 control-plane || exit 1
crear_vm "$MV_INFRA" 192.168.56.21 080027111121 080027111131 18080 infra       || exit 1
crear_vm "$MV_APP"   192.168.56.22 080027111122 080027111132 18081 app         || exit 1

echo "==> Arrancando las VM ($VBOX_TYPE) ..."
for MV in "${MVS[@]}"; do
  if vm_arrancada "$MV"; then
    echo "  $MV: ya esta arrancada"
  else
    VBoxManage startvm "$MV" --type "$VBOX_TYPE" || exit 1
  fi
done

if [ "${SKIP_INIT:-0}" = 1 ]; then
  echo "SKIP_INIT=1: no se configura kubeadm."
  exit 0
fi

echo "==> Configurando kubeadm dentro de las VM (guestcontrol, sin Vagrant) ..."
bash "$ROOT_DIR/scripts/kubeadm-init-vbox.sh" || exit 1

echo
echo "LISTO:"
echo "  http://127.0.0.1:18080/  (worker infra)"
echo "  http://127.0.0.1:18081/  (worker app)"
echo "  http://127.0.0.1:18082/  (control-plane)"
