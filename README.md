# CDA Chat

CDA Chat is a small Kubernetes lab: a Node.js chat app (web UI + REST API + WebSocket) backed by MariaDB and NATS, with Prometheus, Grafana, and an nginx edge router.

- **Chat replicas** scale from 1 to 3 via a CPU-based HPA and share messages/presence through NATS (MariaDB stores history).
- **Stateful/edge services** (MariaDB, NATS, Prometheus, Grafana, nginx) stay fixed.

```
Browser -> nginx (:80 / host 18080 in the kubeadm lab, 8080 in k3d)
             ├─ /           -> chat-server-service:8080 (UI)
             ├─ /api/       -> chat-server-service:8080 (REST)
             ├─ /ws/        -> chat-server-service:8080 (WebSocket)
             └─ /grafana/   -> grafana-service:3000

chat-server replicas -> nats-service:4222 and mariadb-service:3306
```

## Quick start: kubeadm lab on Docker (recommended)

The supported way to run the kubeadm lab uses **Docker only**. Vagrant is not
installed on the host: it lives in a small controller container that talks to
the host Docker daemon through `/var/run/docker.sock`. The five cluster nodes
are created as sibling containers and keep running after the controller exits.

**Prerequisite:** Docker. Nothing else — no Vagrant, no VirtualBox, no host
`kubectl`. Your user must be able to talk to the Docker daemon (be in the
`docker` group or use `sudo`); because the scripts mount `/var/run/docker.sock`
and run `--privileged` containers, this is effectively root-level access.

```bash
bash scripts/kubeadm-in-docker.sh                       # build controller + start lab
bash scripts/kubeadm-verify-in-docker.sh                # swap/CNI/Ready + HPA + pod/worker failures
bash scripts/kubeadm-controlplane-failure-in-docker.sh  # optional: stop the control plane
bash scripts/kubeadm-down-in-docker.sh                  # teardown
```

| Service | URL |
| --- | --- |
| Chat web UI | <http://localhost:18080/> |
| Grafana | <http://localhost:18080/grafana/> |
| Chat health | <http://localhost:18080/api/health> |

What the scripts do:

1. Build `cda-vagrant-controller` (Vagrant + Docker CLI + SSH client).
2. Build `cda-kubeadm-node` (Debian + containerd + kubelet/kubeadm/kubectl, with
   `KUBELET_EXTRA_ARGS=--fail-swap-on=false`). `K8S_MINOR` is a build arg.
3. Create the isolated network `cda-kubeadm` (`172.28.0.0/16`).
4. Start 5 containers with static IPs on that LAN — no default `bridge`:

   | Node | IP |
   | --- | --- |
   | controlplane | `172.28.0.10` |
   | grafana | `172.28.0.11` |
   | db | `172.28.0.12` |
   | chat | `172.28.0.13` |
   | nginx | `172.28.0.14` |

   The controller container itself is `172.28.0.2`. Vagrant SSH is forced to
   use these LAN IPs instead of a host port; the only published SSH bindings
   are loopback-only (`127.0.0.1:2201-2205`) and exist solely because Vagrant's
   Docker provider needs one to report SSH info.

5. Run `kubeadm init` / `kubeadm join`, install Flannel, apply the app manifests.
6. Keep Vagrant state in `.vagrant-kubeadm-docker/` and generated join data in
   `.kubeadm/` (both git-ignored).

`kubectl` is only executed inside the control-plane container:

```bash
vagrant ssh kubeadm-docker-controlplane -c 'sudo kubectl get nodes -o wide'
```

From the host you can also use Docker directly:

```bash
docker exec kubeadm-docker-controlplane sudo kubectl get pods -o wide
```

Because host swap cannot be disabled from a container, kubeadm is invoked with
`--ignore-preflight-errors=Swap` and kubelet with `--fail-swap-on=false`. That is
why the Docker variant works on machines with swap enabled.

If an older run reports `kubeadm-docker-controlplane: Warning: Connection
refused`, it left containers on the default `bridge`. Recreate them on the
isolated network:

```bash
bash scripts/kubeadm-down-in-docker.sh
docker network rm cda-kubeadm 2>/dev/null || true
bash scripts/kubeadm-in-docker.sh
```

Evidence from the checks is written to `docs/evidence/*.txt`.

### Other kubeadm entry points

| Host has | Command | Provider |
| --- | --- | --- |
| Docker only | `bash scripts/kubeadm-in-docker.sh` | Docker via controller container (**recommended**) |
| Vagrant + Docker | `bash scripts/kubeadm-up-docker.sh` | Docker directly |
| Vagrant + VirtualBox | `bash scripts/kubeadm-up.sh` | Debian bookworm VMs (`192.168.56.20-24`) |

Privileges on the host, per variant:

- **Vagrant + VirtualBox:** no root. Run as a normal user in the `vboxusers`
  group (the VirtualBox install loads the kernel modules).
- **Vagrant + Docker:** Vagrant itself does not need root, but your user must be
  in the `docker` group (or have passwordless `sudo docker`) because Vagrant and
  the script call the Docker CLI / talk to `/var/run/docker.sock`. That is
  effectively root-level access, but **do not** run these scripts with `sudo`:
  Vagrant/VirtualBox refuse to run as root and root-owned Vagrant state and
  evidence files would be created.
- **Docker only (controller container):** same Docker access requirement; no
  Vagrant needed on the host.

The `kubeadm-verify.sh` and `kubeadm-controlplane-failure.sh` scripts are shared
by all three variants. Select the Docker lab with `KUBEADM_DOCKER=1` (the
`*-in-docker.sh` wrappers do this for you):

```bash
KUBEADM_DOCKER=1 bash scripts/kubeadm-verify.sh
KUBEADM_DOCKER=1 bash scripts/kubeadm-controlplane-failure.sh
```

Teardown uses `kubeadm-down-in-docker.sh`, `kubeadm-down-docker.sh` or
`kubeadm-down.sh`, respectively. Full architecture, requirement mapping,
scaling and failure analysis: [`docs/KUBEADM_LAB.md`](docs/KUBEADM_LAB.md).

## Repository layout

- `src/chat-server/` – Node.js server (`server.js`, `lib/`, `public/`, `Dockerfile`, `loadgen.js`)
- `kubernetes/cluster-manifests.yaml` – app/infra manifests (DB init, MariaDB, chat, NATS, Prometheus, Grafana, nginx, HPA, etc.)
- `kubernetes/nginx-configmap.yaml` / `nginx/default.conf` – nginx config
- `kubernetes/demo/load-generator.yaml` – optional HPA load Job
- `docker/kubeadm-node/Dockerfile` – kubeadm node image (Debian + K8s tools)
- `docker/vagrant-controller/Dockerfile` – Vagrant controller image for Docker-only hosts
- `Vagrantfile.kubeadm.docker` – 1 control-plane + 4 workers as Docker containers
- `Vagrantfile.kubeadm` – same topology as VirtualBox VMs (Debian bookworm)
- `scripts/kubeadm-*.sh` – start / verify / failure tests / teardown
- `docs/KUBEADM_LAB.md` – architecture and analysis
- `k3d-cluster.yaml`, `Vagrantfile`, `Vagrantfile.docker` – original k3d/k3s labs (below)

## Original labs (k3d / k3s)

These are still available, but the kubeadm lab above is the one used for the
installation and fault-tolerance requirements.

| Lab | Start | Teardown | Host port |
| --- | --- | --- | --- |
| k3d (k3s in Docker) | `bash scripts/k3d-up.sh` | `bash scripts/k3d-down.sh` | 8080 |
| Vagrant + VirtualBox (k3s) | `vagrant up` | `vagrant destroy -f` | 8080 |
| Vagrant + Docker (k3s) | `bash scripts/vagrant-docker-up.sh` | `bash scripts/vagrant-docker-down.sh` | 8080 |

The k3d lab needs `k3d` and host `kubectl`. The Vagrant k3s labs use
`k3s kubectl` on the master instead. Prometheus' `k3s-nodes` static targets in
`kubernetes/cluster-manifests.yaml` reference the VirtualBox IPs, so they only
resolve in that lab; chat pod scraping and CPU-based HPA work everywhere.

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
- **WebSocket:** connect to `ws://<host>/ws/` (or `wss/`). Client sends `join`, `message`, `typing`, `ping`; server emits `hello`, `joined`, `message`, `presence`, `profile`, `typing`, `pong`, `error`.
- **Metrics:** Prometheus metrics at `:9091/metrics` on each chat pod/container (not exposed via nginx/service).

## Configuration

Key environment variables (see `src/chat-server/lib/config.js`): `PORT` (8080), `METRICS_PORT` (9091), `NATS_URL`, `DB_HOST`/`DB_PORT`/`DB_NAME`/`DB_USER`/`DB_PASSWORD`, and limits like `HISTORY_LIMIT`, `MAX_MESSAGE_LENGTH`. Kubernetes demo credentials are in the `chat-db-credentials` Secret in `kubernetes/cluster-manifests.yaml`.

Useful overrides for the kubeadm lab:

```bash
K8S_MINOR=1.35 bash scripts/kubeadm-up-docker.sh
KUBEADM_NODE_IMAGE=my-node bash scripts/kubeadm-in-docker.sh
```

## Notes

- **No authentication** (lab project). Nicknames are self-asserted.
- DB schema is initialized by `mariadb-init` ConfigMap on first boot with an empty volume and also ensured by `src/chat-server/lib/db.js` (keep them in sync).
- No setup does node/VM autoscaling; the HPA scales chat pods only.
- Mounting `/var/run/docker.sock` into the controller gives it root-equivalent access to the host Docker daemon. Use it only on your own machine.
