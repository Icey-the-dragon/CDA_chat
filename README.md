# CDA Chat

CDA Chat is a small Kubernetes lab: a Node.js chat app (web UI + REST API + WebSocket) backed by MariaDB and NATS, with Prometheus, Grafana, and an nginx edge router.

- **Chat replicas** can scale from 1 to 3 via a CPU-based HPA and share messages/presence through NATS (MariaDB stores history).
- **Stateful/edge services** (MariaDB, NATS, Prometheus, Grafana, nginx) stay fixed.

```
Browser -> nginx (:80 / host 8080)
             ├─ /           -> chat-server-service:8080 (UI)
             ├─ /api/       -> chat-server-service:8080 (REST)
             ├─ /ws/        -> chat-server-service:8080 (WebSocket)
             └─ /grafana/   -> grafana-service:3000

chat-server replicas -> nats-service:4222 and mariadb-service:3306
```

## Repository layout

- `src/chat-server/` – Node.js server (`server.js`, `lib/`, `public/`, `Dockerfile`, `loadgen.js`)
- `kubernetes/cluster-manifests.yaml` – app/infra manifests (DB init, MariaDB, chat, NATS, Prometheus, Grafana, nginx, HPA, etc.)
- `kubernetes/nginx-configmap.yaml` / `nginx/default.conf` – nginx config
- `kubernetes/demo/load-generator.yaml` – optional HPA load Job
- `k3d-cluster.yaml`, `scripts/` – local Docker-based Kubernetes (k3d) setup
- `Vagrantfile` – multi-VM k3s lab (VirtualBox) setup

## Run with Docker + k3d (recommended)

Runs the lab as a local multi-node **Kubernetes (k3s) cluster in Docker** using [k3d](https://k3d.io/) — no VirtualBox VMs, but still managed by Kubernetes (`kubectl`, Deployments/Services/PVCs/HPA) with the same manifests.

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) running (Docker Desktop on Windows/macOS; Engine on Linux)
- [k3d](https://k3d.io/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

**Windows:** install Docker Desktop (WSL2 backend recommended), then install tools, for example:

```powershell
winget install k3d.k3d
winget install Kubernetes.kubectl
```

(or use Chocolatey/Scoop/binaries). You can run the helper script from **Git Bash** or **WSL**, or use the PowerShell steps below.

### Start the cluster

#### Linux / macOS / Windows (Git Bash or WSL)

From the repository root:

```bash
bash scripts/k3d-up.sh
```

This builds the chat image, creates a 5-node cluster (`cda-chat`, context `k3d-cda-chat`) with role labels matching the manifests, imports the image, and applies `kubernetes/`.

#### Windows (PowerShell, manual)

```powershell
# From the repository root
docker build -t chat-server:latest src/chat-server
k3d cluster create --config k3d-cluster.yaml
kubectl --context k3d-cda-chat wait --for=condition=Ready nodes --all --timeout=180s

# Label nodes to match manifest nodeSelectors
$server = (kubectl --context k3d-cda-chat get nodes -o name | Where-Object { $_ -match '-server-' } | Select-Object -First 1) -replace '^node/',''
$agents = kubectl --context k3d-cda-chat get nodes -o name | Where-Object { $_ -match '-agent-' } | ForEach-Object { $_ -replace '^node/','' } | Sort-Object

kubectl --context k3d-cda-chat label node $server role=control-plane --overwrite
kubectl --context k3d-cda-chat taint node $server node-role.kubernetes.io/control-plane:NoSchedule- 2>$null
kubectl --context k3d-cda-chat taint node $server node-role.kubernetes.io/master:NoSchedule- 2>$null
kubectl --context k3d-cda-chat label node $agents[0] role=grafana --overwrite
kubectl --context k3d-cda-chat label node $agents[1] role=db --overwrite
kubectl --context k3d-cda-chat label node $agents[2] role=chat --overwrite
kubectl --context k3d-cda-chat label node $agents[3] role=nginx --overwrite

k3d image import chat-server:latest -c cda-chat
kubectl --context k3d-cda-chat apply -f kubernetes/cluster-manifests.yaml -f kubernetes/nginx-configmap.yaml
```

### Access

| Service | URL |
| --- | --- |
| Chat web UI | <http://localhost:8080/> |
| Grafana | <http://localhost:8080/grafana/> |
| Chat health | <http://localhost:8080/api/health> |

Check status:

```bash
kubectl --context k3d-cda-chat get nodes -L role
kubectl --context k3d-cda-chat get pods -o wide
kubectl --context k3d-cda-chat get hpa chat-server
```

### After changing chat server code

```bash
docker build -t chat-server:latest src/chat-server
k3d image import chat-server:latest -c cda-chat
kubectl --context k3d-cda-chat rollout restart deployment/chat-server
```

(`imagePullPolicy: IfNotPresent` means pods must be restarted to pick up a re-imported `latest` image.)

### HPA/load demo (optional)

```bash
kubectl --context k3d-cda-chat apply -f kubernetes/demo/load-generator.yaml
kubectl --context k3d-cda-chat get hpa chat-server -w
kubectl --context k3d-cda-chat get pods -l app=chat-server -w
```

Remove demo artifacts:

```bash
kubectl --context k3d-cda-chat delete job chat-loadgen
```

### Teardown

```bash
bash scripts/k3d-down.sh
# or: k3d cluster delete cda-chat
```

### Notes

- Nodes are Docker containers on one host (not separate VMs), but scheduling/manifests/HPA work like a Kubernetes cluster.
- Prometheus `k3s-nodes` static targets in `kubernetes/cluster-manifests.yaml` are Vagrant IPs and won’t resolve in k3d; chat pod scraping and CPU-based HPA still work.
- MariaDB/Grafana PVCs use k3d’s default local-path storage class.

## Run with Vagrant + VirtualBox (multi-VM k3s)

This option creates separate VMs (1 master + 4 workers) with k3s. Prerequisites: [Vagrant](https://developer.hashicorp.com/vagrant/install), [VirtualBox](https://www.virtualbox.org/), and Docker on the host (to build the chat image).

1. **Build and save the chat image** (there is no registry; the chat worker preloads it):

   ```bash
   mkdir -p images
   docker build -t chat-server:latest src/chat-server
   docker save -o images/chat-server.tar chat-server:latest
   ```

2. **Bring the cluster up:**

   ```bash
   vagrant up
   ```

   The master applies `kubernetes/` manifests. Open <http://localhost:8080/> and <http://localhost:8080/grafana/> when pods are ready.

3. **After changing chat server code:**

   ```bash
   docker build -t chat-server:latest src/chat-server
   docker save -o images/chat-server.tar chat-server:latest
   vagrant rsync k3s-worker-chat
   vagrant ssh k3s-worker-chat -c "sudo k3s ctr images import /vagrant/images/chat-server.tar"
   vagrant ssh k3s-master -c "sudo k3s kubectl rollout restart deployment/chat-server"
   ```

Useful: `vagrant ssh k3s-master -c "sudo k3s kubectl get pods -o wide"`.

### Alternative: Vagrant with Docker provider (experimental)

`Vagrantfile.docker` is an experimental alternative that uses **Docker containers** as Vagrant "machines" instead of VirtualBox VMs (and provisions k3s inside them).

- Prerequisites: [Vagrant](https://developer.hashicorp.com/vagrant/install) and Docker (no VirtualBox). Linux hosts work best; privileged/systemd containers can be less reliable on Docker Desktop (Windows/macOS/WSL2).
- Run from a shell with `bash`, `docker`, and `vagrant` available (Linux/macOS, or Git Bash/WSL on Windows).

**Start (full setup):**

```bash
bash scripts/vagrant-docker-up.sh
```

This builds the chat image and saves `images/chat-server.tar`, ensures the `cda-vagrant` Docker network exists, and runs `vagrant --vagrantfile=Vagrantfile.docker up --provider=docker`.

**Teardown:**

```bash
bash scripts/vagrant-docker-down.sh
```

This destroys the Vagrant machines and removes the `cda-vagrant` Docker network (set `REMOVE_NETWORK=0` to keep it).

Manual equivalent:

```bash
docker network create cda-vagrant   # once
mkdir -p images && docker build -t chat-server:latest src/chat-server && docker save -o images/chat-server.tar chat-server:latest
vagrant --vagrantfile=Vagrantfile.docker up --provider=docker

# teardown
vagrant --vagrantfile=Vagrantfile.docker destroy -f
docker network rm cda-vagrant
```

This is less battle-tested than the VirtualBox or k3d setups; for a simpler Docker-based Kubernetes workflow, prefer the **k3d** option above.

## Local development (without Kubernetes)

Requires Node.js 20+, MariaDB, and NATS (chat starts without NATS, but cross-replica realtime/readiness needs it).

```bash
docker run --rm --name cda-mariadb \
  -e MYSQL_ROOT_PASSWORD=secretpassword-owo -e MYSQL_DATABASE=chatapp \
  -e MYSQL_USER=chat -e MYSQL_PASSWORD=chatpassword -p 3306:3306 mariadb:11.4

docker run --rm --name cda-nats -p 4222:4222 nats:2.10-alpine

cd src/chat-server
npm install
PORT=3000 NATS_URL=nats://127.0.0.1:4222 npm start
# Windows PowerShell: $env:PORT=3000; $env:NATS_URL="nats://127.0.0.1:4222"; npm start
```

Open <http://localhost:3000>. Tables are created automatically on startup.

## API and realtime (summary)

- **Health/readiness:** `GET /api/livez`, `GET /api/health`, `GET /api/ready` (ready requires MariaDB + NATS)
- **Rooms:** `GET /api/rooms`, `POST /api/rooms` `{ "name":"random" }`
- **Messages:** `GET /api/messages?room=general&limit=50&before=<id>`, `POST /api/messages` `{ "room","username","body" }`
- **Profiles:** `GET /api/profile?username=...`, `PUT /api/profile` `{ "username","avatar","color" }`
- **WebSocket:** connect to `ws://<host>/ws/` (or `wss://`). Client sends `join`, `message`, `typing`, `ping`; server emits `hello`, `joined`, `message`, `presence`, `profile`, `typing`, `pong`, `error`.
- **Metrics:** Prometheus metrics at `:9091/metrics` on each chat pod/container (not exposed via nginx/service).

## Configuration

Key environment variables (see `src/chat-server/lib/config.js`): `PORT` (8080), `METRICS_PORT` (9091), `NATS_URL`, `DB_HOST`/`DB_PORT`/`DB_NAME`/`DB_USER`/`DB_PASSWORD`, and limits like `HISTORY_LIMIT`, `MAX_MESSAGE_LENGTH`. Kubernetes demo credentials are in the `chat-db-credentials` Secret in `kubernetes/cluster-manifests.yaml`.

## Notes

- **No authentication** (lab project). Nicknames are self-asserted.
- DB schema is initialized by `mariadb-init` ConfigMap on first boot with an empty volume and also ensured by `src/chat-server/lib/db.js` (keep them in sync).
- k3d runs on a single Docker host; Vagrant provides separate VMs. Neither setup does automatic node/VM autoscaling (HPA scales chat pods only).
- The chat image is distributed locally (`k3d image import` or preloaded tarball), not via a registry.
