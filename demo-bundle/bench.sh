#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

N="${N:-20}"          # número de peticiones
PAR="${PAR:-10}"      # peticiones concurrentes
PF_LOG="${PF_LOG:-/tmp/cda-demo-portforward.log}"
PF_PID="${PF_PID:-/tmp/cda-demo-portforward.pid}"

# "Sin balanceo" = port-forward directo a un pod concreto (:8081).
# "Con balanceo" = Service de Kubernetes (:8080), que reparte entre réplicas.
ensure_direct() {
  if curl -fsS --max-time 2 http://127.0.0.1:8081/healthz >/dev/null 2>&1; then
    return 0
  fi

  local pod
  pod="$(kubectl get pods -l app=demo --field-selector=status.phase=Running \
          -o jsonpath='{.items[0].metadata.name}')"
  if [ -z "$pod" ]; then
    echo "No hay pods 'demo' en Running. Ejecuta primero bash start.sh" >&2
    exit 1
  fi

  echo "==> Abriendo port-forward directo a $pod en 127.0.0.1:8081"
  nohup kubectl port-forward "pod/$pod" 8081:8080 --address 127.0.0.1 \
    >"$PF_LOG" 2>&1 &
  echo $! >"$PF_PID"

  for _ in $(seq 1 20); do
    if curl -fsS --max-time 1 http://127.0.0.1:8081/healthz >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  echo "El port-forward no arrancó. Revisa $PF_LOG" >&2
  exit 1
}

measure() {
  local url="$1" t0 t1
  t0="$(date +%s%N)"
  seq 1 "$N" | xargs -P "$PAR" -I{} \
    curl -sS -o /dev/null --max-time 15 "$url"
  t1="$(date +%s%N)"
  echo $(( (t1 - t0) / 1000000 ))
}

ensure_direct

echo "==> $N peticiones, $PAR concurrentes, 300 ms de CPU por petición"
direct_ms="$(measure http://127.0.0.1:8081/api/slow)"
balanced_ms="$(measure http://localhost:8080/api/slow)"

printf 'Sin balanceo (1 pod, :8081):   %6s ms\n' "$direct_ms"
printf 'Con balanceo (Service, :8080): %6s ms\n' "$balanced_ms"
if [ "$balanced_ms" -gt 0 ] && [ "$direct_ms" -gt "$balanced_ms" ]; then
  echo "=> El balanceo reparte la carga y termina antes."
fi
