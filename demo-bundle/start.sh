#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

CLUSTER="${CLUSTER_NAME:-cda-demo}"
IMAGE="${IMAGE_NAME:-cda-demo:latest}"

for cmd in docker k3d kubectl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Falta '$cmd'. Instala Docker, k3d y kubectl (ver README.md)." >&2
    exit 1
  fi
done

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "==> Cargando imagen $IMAGE desde images/cda-demo.tar"
  docker load -i images/cda-demo.tar
fi

# Optional: the bundle may include the exact k3s image used to build it.
if [ -f images/k3s.tar ] && [ -f images/k3s-image.txt ]; then
  K3S_IMAGE="$(cat images/k3s-image.txt)"
  if ! docker image inspect "$K3S_IMAGE" >/dev/null 2>&1; then
    echo "==> Cargando k3s $K3S_IMAGE desde images/k3s.tar"
    docker load -i images/k3s.tar
  fi
fi

if k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$CLUSTER"; then
  echo "==> El cluster '$CLUSTER' ya existe, se reutiliza"
else
  echo "==> Creando cluster '$CLUSTER' (1 control-plane + 2 workers)"
  k3d cluster create --config k3d-cluster.yaml
fi

CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
if [ "$CONTEXT" != "k3d-${CLUSTER}" ]; then
  echo "==> Cambiando contexto a k3d-${CLUSTER} (actual: ${CONTEXT:-ninguno})"
  kubectl config use-context "k3d-${CLUSTER}"
fi

echo "==> Importando la imagen en los 3 nodos"
k3d image import "$IMAGE" -c "$CLUSTER"

echo "==> Reservando el control-plane para el plano de control"
kubectl taint nodes -l node-role.kubernetes.io/control-plane \
  node-role.kubernetes.io/control-plane:NoSchedule --overwrite >/dev/null

echo "==> Aplicando Deployment + Service + HPA"
kubectl apply -f manifests/demo.yaml
kubectl rollout status deployment/demo --timeout=180s

# The HPA cannot compute CPU targets until metrics-server has scraped the
# kubelets. Wait here so demo 2 works immediately.
echo "==> Esperando a metrics-server (necesario para el HPA)"
for _ in $(seq 1 60); do
  if kubectl top pods -l app=demo >/dev/null 2>&1; then
    echo "metrics-server listo"
    break
  fi
  sleep 2
done
if ! kubectl top pods -l app=demo >/dev/null 2>&1; then
  echo "Aviso: metrics-server no responde; el escalado automático puede fallar." >&2
fi

echo
echo "==> Entorno listo"
kubectl get nodes -o wide
echo
kubectl get pods -o wide
echo
echo "Abre http://localhost:8080/ y sigue el README.md para las 4 demos."
