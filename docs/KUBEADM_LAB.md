# Laboratorio paralelo con kubeadm (1 master + 4 workers)

Este documento describe el entorno **kubeadm** añadido en paralelo al setup
actual (k3d / Vagrant+k3s). No modifica ni reemplaza esos setups: usa otras IPs,
otro puerto de host y un directorio de estado de Vagrant distinto.

| Entorno | Herramienta | Nodos | Puerto chat | Estado Vagrant |
|---|---|---|---|---|
| Actual (k3d) | k3s en contenedores Docker | 1 server + 4 agents | 8080 | – |
| Actual (Vagrant) | k3s en VMs | 1 master + 4 workers | 8080 | `.vagrant/` |
| **Nuevo (este doc)** | **kubeadm sobre VMs Ubuntu** | **1 control-plane + 4 workers** | **18080** | `.vagrant-kubeadm/` |

---

## 1. Contextualización

Kubernetes es una plataforma para ejecutar y gestionar contenedores en un
clúster. Separa dos tipos de nodos:

- **Control plane (antiguamente "master")**: decide *qué* se ejecuta y *dónde*.
  - `kube-apiserver`: API HTTP/gRPC; único punto de escritura del clúster.
  - `etcd`: base de datos de clave-valor que guarda **todo** el estado del clúster.
  - `kube-scheduler`: asigna pods a nodos.
  - `kube-controller-manager`: controladores (Deployments, ReplicaSets, nodos, etc.).
  - `cloud-controller-manager` (no usado en este laboratorio local).
- **Worker nodes**: ejecutan los pods.
  - `kubelet`: agente que arranca contenedores through el CRI y reporta al API.
  - `kube-proxy`: reglas de red para los Services.
  - Container runtime: **containerd** en este laboratorio.

**kubeadm** es la herramienta oficial de arranque: hace los pre-checks, genera
los certificados, crea los manifiestos estáticos del control plane, emite un
token de unión y permite añadir workers con `kubeadm join`. No gestiona el
sistema operativo ni instala la CNI: eso se hace por separado (aquí, swap
desactivada y **Flannel** como CNI).

Objetos usados por la aplicación: `Deployment`, `ReplicaSet`, `Pod`, `Service`,
`ConfigMap`, `Secret`, `PersistentVolumeClaim`, `HorizontalPodAutoscaler` y
`PodDisruptionBudget`.

---

## 2. Arquitectura del laboratorio

```
                      host (VirtualBox / Vagrant)
                      puerto 18080 -> 30080
                              |
                    +---------------------+
                    |  nginx-router pod   |  role=nginx
                    +----------+----------+
                               |
        +----------------------+----------------------+
        |                      |                      |
  chat-server pods      MariaDB + PVC         Prometheus + Grafana
  (HPA 1..3)             role=db               role=grafana
  workload=chat
        |
  NATS (event bus)  --- control-plane (role=control-plane, sin taint)
                              |
                    +---------+----------+
                    |  API + etcd + scheduler + CM |
                    +-----------------------------+
```

### Nodos

| VM | IP | Rol kubeadm | Etiquetas | Memoria / CPU |
|---|---|---|---|---|
| `kubeadm-controlplane` | 192.168.56.20 | control-plane | `role=control-plane` | 2048 MB / 2 |
| `kubeadm-worker-grafana` | 192.168.56.21 | worker | `role=grafana` | 1024 MB / 1 |
| `kubeadm-worker-db` | 192.168.56.22 | worker | `role=db` | 1536 MB / 1 |
| `kubeadm-worker-chat` | 192.168.56.23 | worker | `role=chat`, `workload=chat` | 1536 MB / 2 |
| `kubeadm-worker-nginx` | 192.168.56.24 | worker | `role=nginx`, `workload=chat` | 1024 MB / 1 |

Se añade `workload=chat` a dos workers y se parchea el `nodeSelector` del
Deployment `chat-server` para que use esa etiqueta. Así los pods de chat pueden
reubicarse si falla el worker de chat. Los manifiestos compartidos
(`kubernetes/cluster-manifests.yaml`) no se modifican: el cambio se aplica solo
a este clúster desde `scripts/kubeadm-up.sh`.

Detalles de red: CNI Flannel con `--pod-network-cidr=10.244.0.0/16`;
containerd con `SystemdCgroup = true`; swap desactivada vía `swapoff -a` y
comentando `/etc/fstab` en **todos** los nodos; versión de Kubernetes
configurable con `K8S_MINOR` (por defecto `1.36`).

---

## 3. Cumplimiento de requisitos

| Requisito | Cómo se cubre aquí |
|---|---|
| Instalar clúster con **kubeadm** | `Vagrantfile.kubeadm` + `scripts/kubeadm-up.sh`: `kubeadm init` y `kubeadm join`. |
| Contextualización y arquitectura | Secciones 1 y 2 de este documento. |
| **1 master + 2 workers** (mínimo) | Se crean **1 control-plane + 4 workers**, mismo número que el setup actual (el requisito pide dos; aquí hay cuatro para conservar la topología de la app). |
| Deshabilitar swap | `swapoff -a` + `sed` en `/etc/fstab` en la provision común. Verificado por `scripts/kubeadm-verify.sh`. |
| Configurar CNI (Flannel/Calico) hasta `Ready` | Flannel aplicado en el master; el script espera `kubectl wait --for=condition=Ready nodes --all` ejecutado **dentro del control-plane**. |
| Verificar **escalado** | HPA v2 (1→3 réplicas, 60% CPU) + Job `load-generator`; verificado en el paso 4 del script. |
| Analizar **tolerancia a fallos** | Pruebas de pod, worker y control-plane + análisis en la sección 5. |

---

## 4. Puesta en marcha

Prerrequisitos en el host: Vagrant + VirtualBox, Docker y conexión a Internet
(para las imágenes y el repo apt de Kubernetes). **No hace falta instalar
`kubectl` en el host**: todos los comandos `kubectl` se ejecutan dentro del
control-plane mediante `vagrant ssh kubeadm-controlplane -c 'sudo kubectl ...'`.

```bash
bash scripts/kubeadm-up.sh          # construye la imagen, inicializa y despliega
bash scripts/kubeadm-verify.sh      # comprueba swap, CNI, HPA y fallos de pod/worker
bash scripts/kubeadm-controlplane-failure.sh   # opcional: fallo del control-plane
bash scripts/kubeadm-down.sh        # destroy -f; no toca k3d/k3s
```

Overrides útiles:

```bash
K8S_MINOR=1.35 bash scripts/kubeadm-up.sh
```

Accesos:

- Chat UI: <http://localhost:18080/>
- Grafana: <http://localhost:18080/grafana/>
- Health: <http://localhost:18080/api/health>
- kubeconfig: `/etc/kubernetes/admin.conf` (solo dentro de `kubeadm-controlplane`)

Ejemplos (se ejecutan en el host pero corren **dentro del master**):

```bash
vagrant ssh kubeadm-controlplane -c 'sudo kubectl get nodes -o wide'
vagrant ssh kubeadm-controlplane -c 'sudo kubectl get hpa chat-server'
vagrant ssh kubeadm-controlplane -c 'sudo kubectl logs deploy/chat-server'
```

Notas sobre el despliegue de la app:

- El master aplica `/vagrant/kubernetes/cluster-manifests.yaml` y
  `/vagrant/kubernetes/nginx-configmap.yaml` (la carpeta del repo está montada
  en `/vagrant` dentro de las VMs).
- `chat-server` se parchea a `nodeSelector: workload: chat` (ver sección 2).
- Prometheus cambia sus targets estáticos de `192.168.56.1x` a
  `192.168.56.2x` y Grafana usa `root_url` con el puerto 18080.
- La imagen `chat-server:latest` se importa en los dos workers con `workload=chat`.

---

## 5. Escalabilidad y tolerancia a fallos

### 5.1 Escalabilidad

`HorizontalPodAutoscaler` (`autoscaling/v2`):

- `minReplicas: 1`, `maxReplicas: 3`
- objetivo: 60% de uso de CPU (sobre `requests.cpu: 100m`)
- scale-up inmediato (periodo 30 s, hasta +100% o +2 pods)
- scale-down con ventana de estabilización de 120 s

Prueba: `scripts/kubeadm-verify.sh` aplica
`/vagrant/kubernetes/demo/load-generator.yaml` (10 workers, 180 s) y espera a que
`status.desiredReplicas >= 2`. El resultado real queda en
`docs/evidence/kubeadm-verify.txt`.

> Puedes completar aquí los valores observados: réplicas antes/después,
> `TARGETS`, tiempo hasta el scale-up y CPU por pod.

### 5.2 Escenarios de fallo

| Escenario | Comportamiento esperado | Evidencia |
|---|---|---|
| Se borra un pod de `chat-server` | El ReplicaSet crea otro pod; el Service deja de enviar tráfico al pod eliminado. | Paso 5 de `kubeadm-verify.sh` |
| Se detiene `kubelet` en `kubeadm-worker-chat` | El nodo pasa a `NotReady`. El pod se elimina de forma acelerada y se reprograma en `kubeadm-worker-nginx` (también `workload=chat`). | Paso 6 de `kubeadm-verify.sh` |
| Se detiene el control-plane | Las cargas ya en ejecución siguen respondiendo, pero `kubectl` deja de funcionar: no se pueden crear/borrar objetos ni hay scheduling nuevo. Al restaurar `kubelet`, el API vuelve. | `kubeadm-controlplane-failure.sh` |
| Falla el worker de DB | MariaDB deja de estar disponible: `mariadb-service` no tiene endpoints y `/api/ready` falla. Los pods de chat siguen corriendo pero pierden historial. | Análisis (no automatizado) |
| Falla el worker de Grafana | Se pierde Prometheus/Grafana; el chat sigue funcionando. | Análisis (no automatizado) |

En el paso 6 se usa `--grace-period=0 --force` para no esperar los ~5 minutos
por defecto del taint de evicción; en una caída real ese es el tiempo que tarda
el control-plane en declarar el nodo como `NotReady` y migrar los pods.

### 5.3 Puntos únicos de fallo (SPOF) y mejoras

Este laboratorio es deliberadamente sencillo, por lo que **no es tolerante a
fallos a nivel de infraestructura**. Los SPOFs son:

1. **Control-plane único**: si falla, se pierde el API y etcd (aquí *stacked*).
   - Mejora: 3 control-planes con `--control-plane-endpoint` tras un balanceador
     y `--upload-certs`; etcd con 3 miembros aguanta 1 fallo (quorum 2/3).
2. **MariaDB único** con PVC `ReadWriteOnce` en un solo worker.
   - Mejora: StatefulSet + replicación (Galera/InnoDB Cluster) o un PVC remoto.
3. **NATS único** en el control-plane.
   - Mejora: clúster NATS de 3 nodos o JetStream con réplicas.
4. **nginx-router único**: todo el tráfico entra por un pod.
   - Mejora: varias réplicas + Service `LoadBalancer`/Ingress con multiple
     réplicas, y `PodDisruptionBudget`.
5. **Prometheus/Grafana únicos**: solo afecta a observabilidad.

Protecciones que **sí** existen:

- `Deployment` + `ReplicaSet` (autocuración de pods).
- `RollingUpdate` con `maxUnavailable: 0` en `chat-server`.
- `PodDisruptionBudget` (`maxUnavailable: 1`) para `chat-server`.
- `topologySpreadConstraints` por hostname (con `ScheduleAnyway`).
- Probes de startup/readiness/liveness en chat, MariaDB y NATS.
- Dos workers con `workload=chat` permiten mover los pods de la app.

---

## 6. Evidencia

Los scripts guardan la salida en:

- `docs/evidence/kubeadm-verify.txt`
- `docs/evidence/kubeadm-controlplane-failure.txt`

(`*.log` está ignorado por Git, por eso se usa extensión `.txt`.) Puedes pegar
los valores observados en las tablas anteriores para entregar el análisis.
