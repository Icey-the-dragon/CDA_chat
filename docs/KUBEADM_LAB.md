# Laboratorio kubeadm: 1 master + 2 workers

Este documento describe el único laboratorio de esta rama: kubeadm sobre
Debian bookworm con Vagrant + VirtualBox. Cumple la topología pedida y añade
HA para los servicios de la aplicación con solo dos workers.

## 1. Contextualización

Kubernetes separa el plano de control de los workers:

- **Control plane** (`kube-apiserver`, `etcd`, `kube-scheduler`,
  `kube-controller-manager`): decide qué se ejecuta y dónde; guarda todo el
  estado del clúster.
- **Workers** (`kubelet`, `kube-proxy`, containerd): ejecutan los pods y
  mantienen las reglas de red de los Services.

**kubeadm** hace los pre-checks, genera certificados, crea los manifiestos
estáticos del control plane, emite el token de unión y permite añadir workers
con `kubeadm join`. No instala la CNI ni gestiona el sistema operativo: aquí
swap se desactiva en la provision y la CNI es **Flannel**.

Objetivos usados: `Deployment`, `ReplicaSet`, `Pod`, `Service`, `ConfigMap`,
`Secret`, `PersistentVolumeClaim`, `HorizontalPodAutoscaler`,
`PodDisruptionBudget` y `StatefulSet` (NATS).

## 2. Arquitectura

```
                    host (VirtualBox)
        18080 (worker infra)      18081 (worker app)
                |                       |
        +-------+------+         +------+-------+
        | nginx-router |         | nginx-router |   edge=nginx
        +-------+------+         +------+-------+
                +---------+---------+
                          |
              chat-server-service:8080 -> chat pods (2..4)
                          |
        +-----------------+------------------+
        |                                    |
  nats-service:4222                  mariadb-service:3306
  (2 servidores)                     (primary + replica + failover)
```

| Nodo | IP | Responsabilidades |
| --- | --- | --- |
| `kubeadm-controlplane` | `192.168.56.20` | API, etcd, scheduler, controller-manager, `mariadb-failover` |
| `kubeadm-worker-infra` | `192.168.56.21` | MariaDB primary, Prometheus, Grafana, nginx, NATS, chat |
| `kubeadm-worker-app` | `192.168.56.22` | MariaDB replica, nginx, NATS, chat, load generator |

Con solo dos workers se usan varias etiquetas en vez de sobrecargar `role`:

| Carga | nodeSelector en kubeadm |
| --- | --- |
| `chat-server` | `workload: chat` (ambos workers) |
| `prometheus`, `grafana` | `monitoring: grafana` (worker infra) |
| `nginx-router` | `edge: nginx` (ambos workers, 2 réplicas) |
| `mariadb-primary` | `role: db` (worker infra) |
| `mariadb-replica` | `role: chat` (worker app) |
| `mariadb-failover` | `role: control-plane` (taint eliminado) |
| `nats` StatefulSet | `nats: enabled` (ambos workers, 2 pods) |

Detalles de red y almacenamiento:

- Flannel se parchea con `Interface: enp0s8` porque la NAT de Vagrant es igual
  en las tres VM (`10.0.2.15`); sin ese cambio todos los nodos anunciarían la
  misma IP de backend.
- `metrics-server` se instala en el arranque con `--kubelet-insecure-tls`.
- Se importa `chat-server:latest` en los dos workers para que la recuperación
  no dependa de descargar imágenes.
- NATS y nginx usan anti-afinidad rígida; chat usa una regla preferida para
  poder crecer a 4 réplicas. nginx usa `maxSurge=0` para no bloquear el paso de
  1 a 2 réplicas en solo dos workers.
- No hay provisioner dinámico: `kubernetes/kubeadm/storage.yaml` crea PV
  `hostPath` estáticos para MariaDB y Grafana.
- Los archivos se suben con el provisioner `file` de Vagrant y se copian a
  `/opt/cda-chat` dentro de cada VM. No hay synced folder `rsync`, lo que evita
  errores de permisos al reconstruir la VM.

## 3. Cumplimiento de requisitos

| Requisito | Cómo se cubre |
| --- | --- |
| Instalar clúster con **kubeadm** | `Vagrantfile.kubeadm` + `scripts/kubeadm-up.sh`: `kubeadm init` y `kubeadm join`. |
| Contextualización y arquitectura | Secciones 1 y 2. |
| **1 master + 2 workers** | Exactamente 1 control-plane y 2 workers; servicios consolidados. |
| Deshabilitar swap | `swapoff -a` y comentario en `/etc/fstab` en la provision común. |
| Configurar CNI hasta `Ready` | Flannel; `kubectl wait --for=condition=Ready nodes --all` dentro del master. |
| Escalado manual y automático | `kubectl scale` y HPA v2 2→4 al 60% de CPU con `metrics-server`. |
| Verificar escalado y tolerancia a fallos | `kubeadm-verify.sh` y `kubeadm-chaos.sh` (11 escenarios). |

## 4. Puesta en marcha

Prerrequisitos: Vagrant + VirtualBox, Docker (para construir la imagen), `curl`
y conexión a Internet la primera vez. No hace falta `kubectl` en el host.

Si Linux tiene cargados módulos KVM, los scripts los descargan cuando hay
`sudo` sin contraseña; si no, muestran el comando exacto. No ejecutar los
scripts con `sudo`.

```bash
bash scripts/kubeadm-up.sh                       # init, join, CNI, HA y app
bash scripts/kubeadm-verify.sh                   # comprobación completa
bash scripts/kubeadm-chaos.sh                    # 11 fallos automatizados
bash scripts/kubeadm-controlplane-failure.sh     # opcional
bash scripts/kubeadm-down.sh                     # destroy -f y limpieza
```

Override de versión:

```bash
K8S_MINOR=1.35 bash scripts/kubeadm-up.sh
```

Accesos:

- Chat UI: <http://localhost:18080/> (infra) o <http://localhost:18081/> (app)
- Grafana: <http://localhost:18080/grafana/>
- Health: <http://localhost:18080/api/health>
- kubeconfig: `/etc/kubernetes/admin.conf` (solo dentro del control-plane)

Ejecución de `kubectl` desde el host (siempre dentro del master):

```bash
vagrant ssh kubeadm-controlplane -c 'sudo kubectl get nodes -o wide'
vagrant ssh kubeadm-controlplane -c 'sudo kubectl get pods -o wide'
vagrant ssh kubeadm-controlplane -c 'sudo kubectl get hpa chat-server'
```

## 5. Escalabilidad

HPA `autoscaling/v2`:

- `minReplicas: 2`, `maxReplicas: 4` (el mínimo garantiza un pod por worker).
- objetivo: 60% de CPU sobre `requests.cpu: 100m`.
- scale-up inmediato (periodo 30 s); scale-down con estabilización de 120 s.
- `metrics-server` se parchea con `--kubelet-insecure-tls` por los certificados
  autofirmados del laboratorio.

`kubeadm-verify.sh` aplica
`/opt/cda-chat/kubernetes/demo/load-generator.yaml` y espera a que
`status.desiredReplicas` supere el valor inicial. El escenario 10 del chaos
repite la carga mientras elimina un pod de chat.

## 6. Suite automática de fallos

`scripts/kubeadm-chaos.sh` inyecta cada fallo, espera la reacción de Kubernetes,
comprueba la función de la aplicación (`POST /api/messages` + `GET
/api/messages`) y restaura el estado. Devuelve 0 solo si todo pasa.

| # | Fallo inyectado | Comportamiento esperado |
| --- | --- | --- |
| 0 | Ninguno (baseline) | 3 nodos `Ready`, 2 chat, 2 nginx, 2 NATS, MariaDB primario y round-trip correcto. |
| 1 | Borrar un pod `chat-server` | El ReplicaSet lo recrea; la API sigue respondiendo. |
| 2 | `kill 1` en un contenedor chat | La liveness reinicia el proceso; la API sigue respondiendo. |
| 3 | Borrar un pod `nginx-router` | La otra réplica sigue y se recrea la primera. |
| 4 | Borrar un pod NATS | Queda el otro servidor y el StatefulSet recrea el pod. |
| 5 | Apagar el worker `app` | chat/nginx/NATS se reubican en `infra`; se prueban los dos puertos. |
| 6 | Apagar el worker `infra` | El failover controller cambia `mariadb-service` al replica; al volver, vuelve al primary. |
| 7 | Apagar el control-plane | La API de Kubernetes cae, pero nginx, chat, NATS y MariaDB siguen en los workers. |
| 8 | Borrar el pod MariaDB activo | El Deployment lo recrea y el tráfico vuelve al servidor correspondiente. |
| 9 | Borrar Prometheus y Grafana | Se recrean; no están en la ruta de petición. |
| 10 | Carga sostenida + borrar un pod chat | El HPA escala y la API sigue respondiendo. |

Los apagados usan `vagrant stop` y luego `vagrant up`; los borrados usan
`--grace-period=0 --force` para no esperar el taint de evicción.

## 7. Puntos únicos de fallo y mejoras

| Componente | Estado en el laboratorio | Mejora para producción |
| --- | --- | --- |
| Control-plane | **SPOF**: sin API no hay scheduling ni failover de MariaDB. Los pods ya en ejecución siguen sirviendo. | 3 control-planes tras LoadBalancer + etcd con quórum 2/3. |
| `mariadb-failover` | Una sola réplica en el control-plane. | Controller con leader election en 3 nodos. |
| MariaDB | Dos servidores con replicación asíncrona y failover del Service. Puede perderse algún mensaje escrito justo antes del fallo. | Galera / InnoDB Cluster con replicación síncrona. |
| NATS | Dos servidores enrutados (aguanta uno caído). | 3 servidores (quórum) o JetStream con réplicas. |
| nginx | Dos réplicas, una por worker, tras el mismo NodePort. | Ingress + VIP / LoadBalancer externo. |
| Prometheus / Grafana | Singulares, pero solo afectan a observabilidad. | StatefulSet con almacenamiento replicado. |

Protecciones existentes: Deployment + ReplicaSet, StatefulSet para NATS,
`RollingUpdate`, PodDisruptionBudget, anti-afinidad por hostname, probes y dos
workers con la imagen precargada. La suite de caos comprueba la aplicación
después de **cada** fallo y limpia los recursos de prueba al salir.

## 8. Evidencia y entrega OVA

Los scripts guardan:

- `docs/evidence/kubeadm-verify.txt`
- `docs/evidence/kubeadm-chaos.txt`
- `docs/evidence/kubeadm-controlplane-failure.txt`

Para entregar una VM lista para arrancar con un solo script (sin Vagrant ni
Docker en el ordenador del profesor), ver
[`docs/OVA_DELIVERY.md`](OVA_DELIVERY.md).
