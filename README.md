# CDA Chat

Laboratorio de Kubernetes para la práctica: **instalar un clúster con kubeadm,
desplegar una aplicación y analizar escalabilidad y tolerancia a fallos**.

La aplicación es un chat React + Node.js con REST/WebSocket, MariaDB y NATS,
más Prometheus/Grafana y nginx como edge. El laboratorio usa exactamente
**1 control-plane + 2 workers** con Vagrant y VirtualBox.

```
Navegador -> nginx NodePort (:30080 -> host 18080/18081)
              ├─ /           -> chat-server-service:8080 (UI React)
              ├─ /api/       -> chat-server-service:8080 (REST)
              ├─ /ws/        -> chat-server-service:8080 (WebSocket)
              └─ /grafana/   -> grafana-service:3000

chat-server (2..4 réplicas) -> nats-service:4222 y mariadb-service:3306
```

## Requisitos en el host

- VirtualBox + Vagrant (el usuario debe estar en `vboxusers`).
- Docker para construir `chat-server:latest` (la imagen se importa en los workers).
- `curl`. **No hace falta `kubectl` en el host**: todos los comandos se ejecutan
  dentro del control-plane con `vagrant ssh ... -c 'sudo kubectl ...'`.
- No ejecutar los scripts con `sudo`.

En Linux, si están cargados los módulos `kvm`, `kvm_intel` o `kvm_amd`,
VirtualBox no puede arrancar las VM. Los scripts lo detectan y, si hay `sudo`
sin contraseña, los descargan automáticamente. Si no, muestran el comando
exacto. También puedes dejarlo preparado con:

```bash
printf 'blacklist kvm\nblacklist kvm_intel\nblacklist kvm_amd\n' | \
  sudo tee /etc/modprobe.d/blacklist-kvm.conf
```

## Laboratorio kubeadm (Vagrant + VirtualBox)

```bash
bash scripts/kubeadm-up.sh                       # crea 1 master + 2 workers y despliega la app
bash scripts/kubeadm-verify.sh                   # swap, CNI, Ready, HA, HPA y fallos
bash scripts/kubeadm-chaos.sh                    # 11 escenarios de fallo automatizados
bash scripts/kubeadm-controlplane-failure.sh     # opcional: caída del control-plane
bash scripts/kubeadm-down.sh                     # destroy -f
```

| Nodo | IP | Servicios |
| --- | --- | --- |
| `kubeadm-controlplane` | `192.168.56.20` | API, etcd, scheduler, failover de MariaDB |
| `kubeadm-worker-infra` | `192.168.56.21` | MariaDB primary, Prometheus, Grafana, nginx/NATS/chat |
| `kubeadm-worker-app` | `192.168.56.22` | MariaDB replica, nginx, NATS, chat, generador de carga |

Accesos:

| Servicio | URL |
| --- | --- |
| Chat UI (worker infra) | <http://localhost:18080/> |
| Chat UI (worker app) | <http://localhost:18081/> |
| Grafana | <http://localhost:18080/grafana/> |
| Health | <http://localhost:18080/api/health> |

Ambos puertos llegan al mismo NodePort, así que si un worker falla el otro
sigue sirviendo la UI. Las pruebas prueban los dos automáticamente.

Ejemplos (se ejecutan en el host pero corren dentro del master):

```bash
vagrant ssh kubeadm-controlplane -c 'sudo kubectl get nodes -o wide'
vagrant ssh kubeadm-controlplane -c 'sudo kubectl get hpa chat-server'
vagrant ssh kubeadm-controlplane -c 'sudo kubectl logs deploy/chat-server'
```

La versión de Kubernetes se puede fijar con `K8S_MINOR`:

```bash
K8S_MINOR=1.35 bash scripts/kubeadm-up.sh
```

El análisis completo de arquitectura, escalado y fallos está en
[`docs/KUBEADM_LAB.md`](docs/KUBEADM_LAB.md). La evidencia se guarda en
`docs/evidence/kubeadm-verify.txt`, `kubeadm-chaos.txt` y
`kubeadm-controlplane-failure.txt`.

## Entrega lista para arrancar con un script (OVA)

Para el profesor: solo VirtualBox + `curl`, sin Vagrant, Docker ni `kubectl`.

```bash
bash scripts/launch-ova.sh demo               # demo mínima: http://127.0.0.1:8080/
bash scripts/launch-ova.sh kubeadm            # laboratorio: http://127.0.0.1:18080/ y :18081/
bash scripts/launch-ova.sh kubeadm verify     # arranca y ejecuta la verificación
bash scripts/launch-ova.sh kubeadm stop
bash scripts/launch-ova.sh kubeadm reset      # borra y reimporta las VM
```

Los `.ova` no están en Git (son grandes). Se generan una vez y se entregan en
`ova/`:

```bash
bash scripts/demo-ova-up.sh
bash scripts/export-ova.sh demo
bash scripts/demo-ova-down.sh

bash scripts/kubeadm-up.sh
bash scripts/export-ova.sh kubeadm
```

Detalles, puertos, los cuatro ejercicios y limitaciones:
[`docs/OVA_DELIVERY.md`](docs/OVA_DELIVERY.md).

## Estructura del repositorio

- `src/chat-server/` – servidor Node.js + React en `frontend/`; `public/` se genera con Vite
- `kubernetes/cluster-manifests.yaml` – manifiestos base (DB, chat, NATS, Prometheus, Grafana, nginx, HPA…)
- `kubernetes/kubeadm/` – overlays HA de kubeadm (NATS, MariaDB + failover) y ConfigMaps de Prometheus
- `Vagrantfile.kubeadm` – 1 control-plane + 2 workers en VirtualBox
- `Vagrantfile.demo` – VM de construcción de `ova/demo.ova`
- `scripts/kubeadm-*.sh` – arranque, verificación, caos, fallo del master y teardown
- `scripts/launch-ova.sh`, `scripts/export-ova.sh`, `scripts/ova-*` – entrega OVA y pruebas sin Vagrant
- `scripts/virtualbox-preflight.sh` – comprueba/descarga módulos KVM que bloquean VirtualBox
- `demo-bundle/` – aplicación demo mínima usada por la OVA `demo`
- `docs/` – análisis del laboratorio y guía de entrega

No hay proveedor Docker ni laboratorios k3d/k3s en esta rama: solo kubeadm con
Vagrant/VirtualBox y las herramientas de prueba/entrega.

## Desarrollo local (sin Kubernetes)

Requiere Node.js 20+, MariaDB y NATS:

```bash
docker run --rm --name cda-mariadb \
  -e MYSQL_ROOT_PASSWORD=secretpassword-owo -e MYSQL_DATABASE=chatapp \
  -e MYSQL_USER=chat -e MYSQL_PASSWORD=chatpassword -p 3306:3306 mariadb:11.4

docker run --rm --name cda-nats -p 4222:4222 nats:2.10-alpine

cd src/chat-server
npm install
npm run build
PORT=3000 NATS_URL=nats://127.0.0.1:4222 npm start
```

Abre <http://localhost:3000>. Para hot reload: `npm run dev:ui` (Vite `:5173`)
y `npm start`. `npm run check` valida tipos y sintaxis.

## API y realtime (resumen)

- **Health:** `GET /api/livez`, `GET /api/health`, `GET /api/ready` (ready exige MariaDB + NATS)
- **Salas:** `GET /api/rooms`, `POST /api/rooms` `{ "name":"random" }`
- **Mensajes:** `GET /api/messages?room=general&limit=50&before=<id>`, `POST /api/messages` `{ "room","username","body" }`
- **Perfiles:** `GET /api/profile?username=...`, `PUT /api/profile` `{ "username","avatar","color" }`
- **WebSocket:** `ws://<host>/ws/`; el cliente envía `join`, `message`, `typing`, `ping`
- **Métricas:** `:9091/metrics` en cada pod de chat (no expuesto por nginx)

## Configuración

Variables principales (`src/chat-server/lib/config.js`): `PORT`, `METRICS_PORT`,
`NATS_URL`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`,
`HISTORY_LIMIT` y `MAX_MESSAGE_LENGTH`. Las credenciales del laboratorio están
en el Secret `chat-db-credentials` de `kubernetes/cluster-manifests.yaml`.

## Notas

- No hay autenticación: es un proyecto de laboratorio.
- El esquema de MariaDB lo inicializa el ConfigMap `mariadb-init` y lo asegura
  `src/chat-server/lib/db.js` en el arranque.
- El HPA escala solo pods de chat; no hay autoscaling de nodos.
- Queda un único control-plane (SPOF documentado). Los pods ya programados
  siguen sirviendo si cae, pero Kubernetes no puede crear ni reemplazar pods.
