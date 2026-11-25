# Laboratorio paralelo con kubeadm (1 master + 2 workers)

Este documento describe el entorno **kubeadm** añadido en paralelo al setup
actual (k3d / Vagrant+k3s). No modifica ni reemplaza esos setups: usa otras IPs,
otro puerto de host y un directorio de estado de Vagrant distinto. Cumple la
topología pedida en la práctica: **un nodo máster y dos nodos esclavos**.

| Entorno | Herramienta | Nodos | Puerto chat | Estado Vagrant |
|---|---|---|---|---|
| Actual (k3d) | k3s en contenedores Docker | 1 server + 4 agents | 8080 | – |
| Actual (Vagrant) | k3s en VMs | 1 master + 4 workers | 8080 | `.vagrant/` |
| **Nuevo (este doc)** | **kubeadm sobre Debian bookworm** | **1 control-plane + 2 workers** | **18080** | `.vagrant-kubeadm/` |

Para entregarlo como VM lista para arrancar con un único script (sin Vagrant
ni Docker en el ordenador del profesor), consulta
[`docs/OVA_DELIVERY.md`](OVA_DELIVERY.md).

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
  - `kubelet`: agente que arranca contenedores a través del CRI y reporta al API.
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

Con solo dos workers, cada worker concentra varias responsabilidades y los
servicios críticos están duplicados. Se usan etiquetas adicionales
(`monitoring`, `edge`, `workload`, `nats`) para no sobrecargar la clave `role`,
que los manifiestos originales usan para un único valor.

```
                    host (VirtualBox / Vagrant / Docker)
             18080 (worker infra)      18081 (worker app)
                    |                        |
            +-------+------+          +-------+------+
            | nginx-router |          | nginx-router |   edge=nginx
            +-------+------+          +-------+------+
                    +---------+--------+
                              |
                  chat-server-service:8080 -> chat pods (2..4)
                         workload=chat (ambos workers)
                              |
              +---------------+----------------+
              |                                |
      nats-service:4222                 mariadb-service:3306
      StatefulSet (2 pods)              -> mariadb-primary o mariadb-replica
      nats=enabled (ambos workers)         (controlador de failover)
              |                                |
      +-------+-------+                +-------+--------+
      | NATS en infra |                | MariaDB primary| infra (role=db)
      +---------------+                +----------------+
      | NATS en app   |                | MariaDB replica| app (role=chat)
      +---------------+                +----------------+

            control-plane: API + etcd + scheduler + controller-manager
                           + mariadb-failover (sin taint NoSchedule)
                           Prometheus/Grafana solo en infra (observabilidad)
```

### Nodos

| VM | IP | Rol kubeadm | Etiquetas | Servicios | Memoria / CPU |
|---|---|---|---|---|---|
| `kubeadm-controlplane` | 192.168.56.20 | control-plane | `role=control-plane` | API, etcd, scheduler, controller-manager, `mariadb-failover` | 1536 MB / 2 |
| `kubeadm-worker-infra` | 192.168.56.21 | worker | `role=db`, `monitoring=grafana`, `edge=nginx`, `nats=enabled`, `workload=chat` | MariaDB primary, Prometheus, Grafana, nginx, NATS, chat | 2048 MB / 2 |
| `kubeadm-worker-app` | 192.168.56.22 | worker | `role=chat`, `edge=nginx`, `nats=enabled`, `workload=chat` | MariaDB replica, nginx, NATS, chat, load-generator | 2048 MB / 2 |

La variante Docker usa las mismas funciones con otras IPs:

| Contenedor | IP | SSH (loopback) |
|---|---|---|
| `kubeadm-docker-controlplane` | `172.28.0.10` | `127.0.0.1:2201` |
| `kubeadm-docker-worker-infra` | `172.28.0.11` | `127.0.0.1:2202` |
| `kubeadm-docker-worker-app` | `172.28.0.12` | `127.0.0.1:2203` |

Detalles de red y sistema:

- CNI **Flannel** con `--pod-network-cidr=10.244.0.0/16`.
- containerd con `SystemdCgroup = true` en VirtualBox. En la variante Docker se
  usa `SystemdCgroup = false` y `--cgroup-driver=cgroupfs` porque los contenedores
  comparten el namespace de cgroups del host y no pueden gestionar los scopes
  de systemd reales.
- Swap desactivada con `swapoff -a` y comentando `/etc/fstab` en **todos** los
  nodos VirtualBox. En Docker no se puede cambiar el swap del host: kubeadm usa
  `--ignore-preflight-errors=Swap` y kubelet usa `--fail-swap-on=false`.
- Versión de Kubernetes configurable con `K8S_MINOR` (por defecto `1.36`).
- `metrics-server` se instala desde el script de arranque; kubeadm no lo trae,
  y el HPA `autoscaling/v2` no puede escalar sin la metrics API.

### Parches específicos de kubeadm

Los manifiestos compartidos (`kubernetes/cluster-manifests.yaml`) solo difieren
de k3d/k3s en la configuración de Grafana (estrategia `Recreate`, `fsGroup: 472`
y un `initContainer` que hace `chown 472:472` del `hostPath`): los volúmenes
`hostPath` ignoran `fsGroup`, así que un directorio recién creado pertenece a
root y el proceso de Grafana (uid 472) no podría escribir en él. La estrategia
`Recreate` evita además que dos pods se disputen el PVC `ReadWriteOnce`.
`scripts/kubeadm-up.sh` y `kubeadm-up-docker.sh`
aplican estos otros cambios solo en este clúster:

| Carga | nodeSelector original | nodeSelector en kubeadm |
|---|---|---|
| `chat-server` | `role: chat` | `workload: chat` (ambos workers) |
| `prometheus` | `role: grafana` | `monitoring: grafana` (worker infra) |
| `grafana` | `role: grafana` | `monitoring: grafana` (worker infra) |
| `nginx-router` | `role: nginx` | `edge: nginx` (ambos workers, 2 réplicas) |
| `mariadb-primary` | – | `role: db` (worker infra) |
| `mariadb-replica` | – | `role: chat` (worker app) |
| `mariadb-failover` | – | `role: control-plane` (taint eliminado) |
| `nats` StatefulSet | `role: control-plane` | `nats: enabled` (ambos workers, 2 pods) |

En la variante Docker, además, el aprovisionamiento del control-plane parchea
dos ConfigMaps del clúster antes de instalar Flannel: `kube-proxy` deja de
escribir los sysctls `nf_conntrack_*` (un contenedor no puede hacerlo) y
CoreDNS pierde el plugin `loop` (el DNS embebido de Docker provoca falsos
positivos de bucle). Sin esos dos cambios, kube-proxy y Flannel entran en
`CrashLoopBackOff` y ningún pod puede obtener red.

Además se añaden reglas de anti-afinidad: NATS y nginx se reparten
obligatoriamente entre los dos workers; chat usa una regla preferida para poder
escalar a 4 réplicas. Para que el anti-affinity rígido de nginx no bloquee el
paso de 1 a 2 réplicas, su Deployment usa `maxSurge=0, maxUnavailable=1`: el pod
antiguo se retira antes de crear el nuevo. La imagen `chat-server:latest` se importa en los dos
workers para que la recuperación ante fallo no dependa de descargar imágenes.
Prometheus usa un ConfigMap propio: `kubernetes/kubeadm/prometheus-config.yaml`
(VirtualBox) o `prometheus-config-docker.yaml` (Docker, con DNS por nombre de
contenedor). kubeadm no trae un provisioner dinámico, así que
`kubernetes/kubeadm/storage.yaml` crea PV `hostPath` estáticos y reservados para
cada PVC (`mariadb-primary`, `mariadb-replica`, `mariadb` y `grafana`) en el nodo
que ya ejecuta ese servicio.

---

## 3. Cumplimiento de requisitos

| Requisito | Cómo se cubre aquí |
|---|---|
| Instalar clúster con **kubeadm** | `Vagrantfile.kubeadm` + `scripts/kubeadm-up.sh`: `kubeadm init` y `kubeadm join`. |
| Contextualización y arquitectura | Secciones 1 y 2 de este documento. |
| **1 master + 2 workers** | Exactamente 1 control-plane y 2 workers, con los servicios consolidados en ellos. |
| Deshabilitar swap | `swapoff -a` + `sed` en `/etc/fstab` en la provision común (en la variante Docker, flags de kubeadm/kubelet). Verificado en el paso 2 de `kubeadm-verify.sh`. |
| Configurar CNI (Flannel/Calico) hasta `Ready` | Flannel aplicado en el master; el script espera `kubectl wait --for=condition=Ready nodes --all` ejecutado **dentro del control-plane**. |
| Verificar **escalado** | HPA v2 (2→4 réplicas, 60% CPU) + `metrics-server` + Job `load-generator`; verificado en el paso 4 de `kubeadm-verify.sh` y en el escenario 10 de `kubeadm-chaos.sh`. |
| Analizar **tolerancia a fallos** | `kubeadm-chaos.sh` inyecta 11 fallos, comprueba después cada uno que la app sigue respondiendo y restaura el clúster; análisis en la sección 5. |

---

## 4. Puesta en marcha

Prerrequisitos en el host: Vagrant + VirtualBox, Docker y conexión a Internet
(para las imágenes y el repo apt de Kubernetes). **No hace falta instalar
`kubectl` en el host**: todos los comandos `kubectl` se ejecutan dentro del
control-plane mediante `vagrant ssh kubeadm-controlplane -c 'sudo kubectl ...'`.

El box por defecto es **`debian/bookworm64`** (más ligero que `ubuntu/jammy64`).
No se usa Alpine: kubeadm se distribuye como paquete `.deb`, espera systemd y
el driver de cgroups `systemd`, mientras Alpine usa OpenRC y no tiene esos
paquetes; la combinación es frágil y no aporta una ventaja real aquí.

```bash
bash scripts/kubeadm-up.sh          # construye la imagen, inicializa y despliega HA
bash scripts/kubeadm-verify.sh      # swap, CNI, HA, HPA, API y fallos de pod/worker
bash scripts/kubeadm-chaos.sh       # 11 fallos automatizados + comprobación de la app
bash scripts/kubeadm-controlplane-failure.sh   # opcional: fallo del control-plane
bash scripts/kubeadm-down.sh        # destroy -f; no toca k3d/k3s
```

Overrides útiles:

```bash
K8S_MINOR=1.35 bash scripts/kubeadm-up.sh
```

Accesos:

- Chat UI: <http://localhost:18080/> (worker infra) o <http://localhost:18081/> (worker app)
- Grafana: <http://localhost:18080/grafana/>
- Health: <http://localhost:18080/api/health>
- kubeconfig: `/etc/kubernetes/admin.conf` (solo dentro de `kubeadm-controlplane`)

Los dos puertos llegan al mismo Service NodePort; si un worker falla, el otro
sigue sirviendo la UI. Los scripts de prueba prueban ambos automáticamente.

Ejemplos (se ejecutan en el host pero corren **dentro del master**):

```bash
vagrant ssh kubeadm-controlplane -c 'sudo kubectl get nodes -o wide'
vagrant ssh kubeadm-controlplane -c 'sudo kubectl get hpa chat-server'
vagrant ssh kubeadm-controlplane -c 'sudo kubectl logs deploy/chat-server'
```

---

## 4.1 Variante rápida con proveedor Docker (experimental)

Si el arranque con VirtualBox es lento, existe una variante que usa el
**proveedor Docker de Vagrant**: los 3 nodos son contenedores privilegiados con
systemd en vez de VMs. Las herramientas de Kubernetes ya vienen horneadas en
`docker/kubeadm-node/Dockerfile`, así que el arranque es mucho más rápido.

```bash
CONTAINERD_SNAPSHOTTER=native bash scripts/kubeadm-in-docker.sh  # Wrapper recomendado; native en Docker Desktop
bash scripts/kubeadm-verify-in-docker.sh
bash scripts/kubeadm-chaos-in-docker.sh                  # 11 fallos automatizados
bash scripts/kubeadm-controlplane-failure-in-docker.sh   # opcional
bash scripts/kubeadm-down-in-docker.sh
```

Si Vagrant está instalado en el host, también se pueden llamar directamente
`scripts/kubeadm-up-docker.sh`, `kubeadm-verify.sh` (con `KUBEADM_DOCKER=1`) y
`kubeadm-down-docker.sh`. En Windows/WSL usa siempre los wrappers `*-in-docker.sh`
desde una ruta ext4 de la distro.

| | VirtualBox (por defecto) | Docker provider (experimental) |
|---|---|---|
| Imagen base | `debian/bookworm64` | `debian:bookworm-slim` + paquetes K8s |
| Arranque | ~30-60 s por VM | ~2-10 s por contenedor (imagen solo se construye la 1ª vez) |
| RAM aproximada | 5-6 GB | 2-3 GB |
| Aislamiento | VM completa | contenedor privilegiado (`--privileged`, cgroupns host) |
| Red | `192.168.56.20-22` | aislada `cda-kubeadm` (`172.28.0.0/16`), IPs fijas **.10-.12** |
| Swap | `swapoff -a` en la VM | no se puede desactivar la del host; `--ignore-preflight-errors=Swap` + kubelet `--fail-swap-on=false` |
| Fiabilidad | alta | dependiente del host; Linux funciona mejor que Docker Desktop |
| Estado Vagrant | `.vagrant-kubeadm/` | `.vagrant-kubeadm-docker/` |

**¿Es más rápido?** Sí, claramente: no hay boot de VM y los paquetes ya están
en la imagen. **Pero** es menos robusto: kubeadm dentro de contenedores con
systemd depende de cgroups, montajes y del kernel del host, y hay que ignorar el
check de swap. Para una entrega donde se evalúa "instalar con kubeadm", la
variante de VirtualBox es la recomendable; la de Docker sirve para iterar
rápido. No ejecutar ambas a la vez: los puertos y nombres podrían solaparse.
`K8S_MINOR` funciona en ambas variantes; en Docker se pasa como build arg al
construir `cda-kubeadm-node` (`K8S_MINOR=1.35 bash scripts/kubeadm-up-docker.sh`).

Sobre el swap: dentro de un contenedor no se puede desactivar el swap del host.
Además de `--ignore-preflight-errors=Swap`, la imagen de los nodos incluye un
drop-in de systemd con `KUBELET_EXTRA_ARGS=--fail-swap-on=false`. Por eso
`kubeadm-verify.sh` comprueba ese flag en la variante Docker en vez de exigir
`swapon --show` vacío.

### 4.2 Sin Vagrant instalado: Vagrant dentro de un contenedor

Sí, se puede. El PC solo necesita **Docker**. La idea no es que Vagrant corra
los nodos *dentro* de su contenedor, sino que el contenedor controlador tenga
Vagrant + Docker CLI y hable con el **Docker Engine del host** mediante
`/var/run/docker.sock` (Docker-outside-of-Docker). Los 3 nodos se crean como
**hermanos** del contenedor controlador en el daemon del host:

```
Host (solo Docker)
  ├── Docker Engine
  ├── (efímero) cda-vagrant-controller  → Vagrant + Docker CLI
  │      y habla por /var/run/docker.sock
  └── 3 contenedores nodo (quedan vivos cuando el controlador sale)
```

```bash
bash scripts/kubeadm-in-docker.sh                    # construye el controlador y corre kubeadm-up-docker.sh
bash scripts/kubeadm-verify-in-docker.sh             # verificación desde el controlador
bash scripts/kubeadm-chaos-in-docker.sh              # 11 fallos automatizados + comprobaciones
bash scripts/kubeadm-controlplane-failure-in-docker.sh  # fallo del control-plane (opcional)
bash scripts/kubeadm-down-in-docker.sh               # teardown
```

**Permisos:** el usuario del PC debe poder hablar con el daemon de Docker
(estar en el grupo `docker` o usar `sudo`). Los scripts montan
`/var/run/docker.sock` y crean contenedores `--privileged` con los cgroups del
host, así que en la práctica es acceso equivalente a root. No hace falta ser
root *dentro* del contenedor controlador: ese contenedor ya corre como root.

**Red aislada (no `bridge`):** los 3 nodos se crean en la red definida por el
usuario `cda-kubeadm` (`172.28.0.0/16`) con IPs fijas `.10` a `.12`. El
controlador está en `.2`, así que cada nodo tiene una IP propia del laboratorio
y no comparte red con otros contenedores del host. La única excepción es el
puertos `18080` y `18081` de nginx, que se publican en el host para poder abrir
la UI aunque falle un worker.

Vagrant tiene una limitación aquí: su proveedor Docker lee
`NetworkSettings.IPAddress` para obtener la IP SSH, y ese campo está vacío en
redes personalizadas. Por eso:

1. cada nodo publica el 22 **solo en `127.0.0.1`** (`2201`-`2203`) para que el
   provider devuelva un `ssh_info` válido;
2. `Vagrantfile.kubeadm.docker` fija `config.ssh.host`/`port` a la IP fija del
   nodo, y esos valores tienen prioridad sobre lo que diga el provider.

Así `vagrant ssh` y el aprovisionamiento siguen funcionando sobre la LAN aislada,
sin binds externos para SSH.

Para las pruebas de fallo, los scripts prueban primero los puertos publicados
`localhost:18080` / `localhost:18081` y, si no responden, usan los nombres DNS
`http://kubeadm-docker-worker-infra:30080/api/health` y
`http://kubeadm-docker-worker-app:30080/api/health`: las redes definidas por el
usuario sí tienen DNS por nombre de contenedor, y desde el controlador
`localhost:18080` no es el puerto publicado en el host.

Detalle clave: cuando Vagrant corre dentro del contenedor, `Dir.pwd` es una
ruta del contenedor que el daemon de Docker no puede ver. Por eso
`Vagrantfile.kubeadm.docker` acepta `NODE_VOLUME_SOURCE`, que el wrapper fija a
la ruta real del repo en el host; así los nodos montan `/vagrant` desde la
ruta correcta. En Windows con Docker Desktop + WSL ese origen debe ser una
ruta ext4 de WSL (por ejemplo `/home/<usuario>/CDA_chat`), no una ruta
`/mnt/e/...` ni una unidad Windows: los bind mounts de Docker Desktop solo
ven el sistema de archivos de la distro WSL. No hace falta `sudo`: el usuario
debe pertenecer al grupo `docker` y los wrappers `*-in-docker.sh` fijan
`VAGRANT_DEFAULT_PROVIDER=docker` para que Vagrant no intente usar `cmd.exe`.
En Docker Desktop el snapshotter de containerd debe ser `native`; con
`overlayfs` el daemon anidado no puede aplicar whiteouts y los pods de sistema
entran en `CrashLoopBackOff`. El wrapper debe ejecutarse con
`CONTAINERD_SNAPSHOTTER=native` (o exportarlo antes).

También es posible prescindir de Vagrant por completo y crear los 3 contenedores
con `docker run`/`docker compose` + `docker exec`, pero los scripts actuales
ya usan Vagrant como capa de provisionamiento y la opción de arriba evita
duplicar esa lógica.

---

## 5. Escalabilidad y tolerancia a fallos

### 5.1 Escalabilidad

`HorizontalPodAutoscaler` (`autoscaling/v2`):

- `minReplicas: 2`, `maxReplicas: 4` (el mínimo ya garantiza un pod por worker).
- objetivo: 60% de uso de CPU (sobre `requests.cpu: 100m`).
- scale-up inmediato (periodo 30 s, hasta +100% o +2 pods).
- scale-down con ventana de estabilización de 120 s.

`metrics-server` se instala en el arranque (`scripts/kubeadm-up*.sh`) y se parchea
con `--kubelet-insecure-tls`, necesario con los certificados autofirmados de
kubeadm en un laboratorio local.

Prueba: `scripts/kubeadm-verify.sh` aplica
`/vagrant/kubernetes/demo/load-generator.yaml` (10 workers, 180 s) y espera a que
`status.desiredReplicas` **supere el valor inicial** (no solo que llegue a 2,
porque ahora el mínimo ya es 2). El escenario 10 de `kubeadm-chaos.sh` repite
la carga mientras elimina un pod de chat. El resultado real queda en
`docs/evidence/kubeadm-verify.txt` y `docs/evidence/kubeadm-chaos.txt`.

Valores observados en la variante Docker (Docker Desktop/WSL, 2026-11-24):
`TARGETS` `cpu: 110%/60%`, HPA de 2 a 4 réplicas (el máximo) en menos de 2
minutos con el Job de carga (10 workers, 75 ms de retardo). El detalle completo
está en `docs/evidence/kubeadm-verify.txt`.

### 5.2 Suite automática de fallos

`scripts/kubeadm-chaos.sh` (o `kubeadm-chaos-in-docker.sh`) hace todo sin
intervención: inyecta el fallo, espera a que Kubernetes reaccione, comprueba que
la **API sigue aceptando y devolviendo mensajes** (`POST /api/messages` + `GET
/api/messages`), restaura el estado y al final devuelve código de salida 0 solo
si todas las comprobaciones pasan. Todas las órdenes `kubectl` se ejecutan dentro
del control-plane.

| # | Fallo inyectado | Comportamiento esperado |
|---|---|---|
| 0 | Ninguno (baseline) | 3 nodos `Ready`, 2 chat, 2 nginx, 2 NATS, MariaDB primario activo y round-trip correcto. |
| 1 | Borrar un pod `chat-server` | El ReplicaSet lo recrea; la API sigue respondiendo. |
| 2 | `kill 1` dentro de un contenedor chat | La liveness/el gestor de señales reinicia el proceso; la API sigue respondiendo. |
| 3 | Borrar un pod `nginx-router` | La segunda réplica sigue en el otro worker y se recrea la primera. |
| 4 | Borrar un pod NATS | Queda el otro servidor y el StatefulSet recrea el pod. |
| 5 | Apagar el worker `app` | chat/nginx/NATS se reubican en `infra`; los dos puertos de host se prueban. |
| 6 | Apagar el worker `infra` | El failover controller cambia `mariadb-service` al replica; al volver `infra`, vuelve al primary. |
| 7 | Apagar el control-plane | La API de Kubernetes deja de responder, pero nginx, chat, NATS y MariaDB siguen en los workers y la API de chat responde. |
| 8 | Borrar el pod MariaDB activo | El Deployment lo recrea y el tráfico vuelve al primario/replica correspondiente. |
| 9 | Borrar Prometheus y Grafana | Se recrean; al no estar en la ruta de petición, la API de chat no se interrumpe. |
| 10 | Carga sostenida + borrar un pod chat | El HPA escala y la API sigue respondiendo durante la sustitución. |

En los apagados de nodo se usa `docker stop` / `vagrant stop` y después se
arranca el nodo; en los borrados de pod se usa `--grace-period=0 --force` para
no esperar los ~5 minutos del taint de evicción. La evidencia incluye los
cambios de `mariadb-service` y el estado final de los nodos.

Resultado observado en la variante Docker (2026-11-24): **27 comprobaciones, 0
fallos**. El failover de MariaDB tardó 171 s en repointar el Service al replica
y 21 s en volver al primary; bajo carga sostenida el HPA alcanzó las 4 réplicas.
El detalle está en `docs/evidence/kubeadm-chaos.txt`.

### 5.3 Puntos únicos de fallo (SPOF) y mejoras

| Componente | Estado en este laboratorio | Mejora para producción |
|---|---|---|
| Control-plane | **SPOF**: sin API no hay scheduling ni failover de MariaDB. Los pods ya en ejecución siguen sirviendo porque nginx, NATS y MariaDB están en los workers. | 3 control-planes tras un LoadBalancer + etcd con quorum 2/3. |
| `mariadb-failover` | Una sola réplica en el control-plane. | Controller con leader election en los 3 nodos. |
| MariaDB | Dos servidores con replicación asíncrona y failover automatizado del Service. Puede perderse algún mensaje escrito justo antes de un fallo; tras el failback el primario puede tener un historial algo desactualizado. | Galera / InnoDB Cluster con replicación síncrona y quorum. |
| NATS | Dos servidores enrutados (aguanta la pérdida de uno). | 3 servidores (quorum) o JetStream con réplicas. |
| nginx | Dos réplicas, una por worker, detrás del mismo NodePort. | Ingress + VIP / LoadBalancer externo. |
| Prometheus / Grafana | Siguen siendo singular, pero solo afectan a observabilidad. | StatefulSet con almacenamiento replicado. |

Protecciones que **sí** existen:

- `Deployment` + `ReplicaSet` (autocuración de pods) y `StatefulSet` para NATS.
- `RollingUpdate` con `maxUnavailable: 0` en `chat-server`.
- `PodDisruptionBudget` (`maxUnavailable: 1`) para `chat-server`.
- `topologySpreadConstraints` + anti-afinidad por hostname.
- Probes de startup/readiness/liveness en chat, MariaDB y NATS.
- Dos workers con las etiquetas `workload`, `edge` y `nats` y la imagen
  precargada permiten mover todos los componentes críticos al superviviente.
- El script de caos comprueba la función de la aplicación (no solo el estado de
  los pods) después de **cada** fallo y limpia los recursos de prueba al salir.

---

## 6. Evidencia

Los scripts guardan la salida en:

- `docs/evidence/kubeadm-verify.txt`
- `docs/evidence/kubeadm-chaos.txt`
- `docs/evidence/kubeadm-controlplane-failure.txt`

(`*.log` está ignorado por Git, por eso se usa extensión `.txt`.) Puedes pegar
los valores observados en las tablas anteriores para entregar el análisis.
