# CDA Chat

A five-node Vagrant + k3s lab that runs MariaDB, a lightweight Node.js chat
server, NATS, Prometheus, Grafana and an nginx router.

The chat server serves three things from one process on port `8080`:

- **REST API** under `/api`
- **WebSocket** live chat under `/ws/`
- **Web UI** (plain HTML/CSS/JS, no build step) at `/`

The lab also demonstrates **pod autoscaling**: the chat Deployment is managed by
a CPU-based HorizontalPodAutoscaler, and multiple chat replicas share messages,
presence and profile updates through a fixed NATS server.

```
Browser ──► localhost:8080
              │
              ▼
        nginx-router (:80, NodePort 30080)          fixed edge node
              ├── /            ──► chat-server-service:8080  (web UI)
              ├── /api/        ──► chat-server-service:8080  (REST)
              ├── /ws/         ──► chat-server-service:8080  (WebSocket)
              └── /grafana/    ──► grafana-service:3000
                                        │
        chat-server (1..3 replicas, HPA) ─┴──► nats-service:4222  fixed control plane
              └── mariadb-service:3306 ──► MariaDB (db worker, PVC)
```

Only the chat pods scale. MariaDB, NATS, Prometheus, Grafana and nginx stay on
their fixed nodes. NATS is what makes the chat replicas behave like one server:
a message accepted by pod A is persisted once and then published to every pod,
so clients connected to pod B receive it too.

## Repository layout

```
kubernetes/
  cluster-manifests.yaml   Secret, MariaDB schema init, MariaDB + chat + NATS +
                           Prometheus + Grafana + nginx, PDB and HPA
  nginx-configmap.yaml     nginx config mounted into the nginx pod
  demo/load-generator.yaml optional load Job used to trigger the HPA
nginx/default.conf         source copy of the nginx config
src/chat-server/
  server.js                HTTP + WebSocket + metrics bootstrap
  loadgen.js               HTTP load generator used by the HPA demo
  lib/                     config, MariaDB access, REST routes, realtime hub, NATS bus
  public/                  web UI (index.html, styles.css, app.js)
  Dockerfile               node:22-alpine production image
Vagrantfile                cluster definition
images/chat-server.tar     locally built image, preloaded by the chat worker (gitignored)
```

The database schema lives in the `mariadb-init` ConfigMap inside
`kubernetes/cluster-manifests.yaml`. MariaDB loads it from
`/docker-entrypoint-initdb.d/` the first time it starts with an empty data
directory, so `vagrant up` sets up the tables with no manual step. On later
boots the PVC already contains the data and the script is skipped.


## 1. Bring the cluster up

```bash
vagrant up
```

The master applies everything in `kubernetes/` after it boots. The chat pods are
pinned to the `role=chat` worker; build the image on the host before
`vagrant up` so that worker can preload it from the synced folder (next step).

MariaDB creates the `chatapp` database and runs the initial schema from the
`mariadb-init` ConfigMap on first boot (empty PVC). This only happens once:
restarting the pod does not recreate tables or wipe messages.

The lab nodes have deliberately different jobs:

| Node | Role | Runs |
| --- | --- | --- |
| `k3s-master` | `control-plane` | k3s server + NATS |
| `k3s-worker-grafana` | `grafana` | Prometheus + Grafana |
| `k3s-worker-db` | `db` | MariaDB + PVC |
| `k3s-worker-chat` | `chat` | 1–3 autoscaled chat pods (1 vCPU, 1.5 GB) |
| `k3s-worker-nginx` | `nginx` | fixed nginx edge, host port 8080 → NodePort 30080 |

NATS, MariaDB, Prometheus, Grafana and nginx have `replicas: 1` and node
selectors. Only the chat Deployment has an HPA. Vagrant/VirtualBox node
autoscaling is out of scope; the demo scales pods on the existing app worker.

Node roles are applied at join time with `--node-label`: `role=<role>` drives the
node selectors and `node-role.kubernetes.io/<role>` fills the `ROLES` column.
No background reconciler is needed. VMs created before those flags existed keep
their original labels until they rejoin the cluster; add them by hand if needed:

```bash
sudo k3s kubectl label node <node> role=<role> node-role.kubernetes.io/<role>= --overwrite
sudo k3s kubectl get nodes -L role
```

`vagrant reload --provision` also works and applies any new VM settings.

## 2. Build and load the chat image

The chat pods are pinned to the `role=chat` worker, so only `k3s-worker-chat`
needs the image. Each k3s node has its own containerd and there is no registry,
so the master cannot serve its images to the worker. Instead:

1. the host builds `images/chat-server.tar` (relative to the repository root),
2. Vagrant's rsync synced folder copies it to every VM (`/vagrant`),
3. the chat worker copies it to `/var/lib/rancher/k3s/agent/images/` before
   k3s starts, and k3s imports it automatically.

Build and save **before** the first `vagrant up`:

```bash
# From the repository root, with Docker running on the host and matching amd64
mkdir -p images
docker build -t chat-server:latest src/chat-server
docker save -o images/chat-server.tar chat-server:latest
vagrant up
```

The tarball is gitignored. If it is missing, provisioning prints a warning and
the chat pods stay in `ErrImagePull`.

### After changing the code

Nothing rebuilds automatically; synced folders only copy files. Rebuild on the
host, push the new tarball, import it into the chat worker, then restart the
Deployment:

```bash
docker build -t chat-server:latest src/chat-server
docker save -o images/chat-server.tar chat-server:latest
vagrant rsync k3s-worker-chat
vagrant ssh k3s-worker-chat -c "sudo k3s ctr images import /vagrant/images/chat-server.tar"
vagrant ssh k3s-master -c "sudo k3s kubectl rollout restart deployment/chat-server"
```

`rollout restart` matters because the manifest uses
`imagePullPolicy: IfNotPresent` with the `latest` tag: kubelet keeps using the
cached image until the pod is recreated. `vagrant reload k3s-worker-chat` also
works, since k3s re-imports the preload directory on startup.

Useful checks:

As k3s master node
```bash
vagrant ssh k3s-master
sudo k3s kubectl get pods -o wide
sudo k3s kubectl logs deploy/chat-server
vagrant ssh k3s-master -c "sudo k3s kubectl logs deploy/mariadb"
```

As chat worker, confirm the image is cached:
```bash
vagrant ssh k3s-worker-chat -c "sudo k3s crictl images | grep chat-server"
```

> The checked-in `kubeconfig.yaml` points at `127.0.0.1:6443`, so using
> `kubectl` directly from the host may require changing the server address to
> `https://192.168.56.10:6443`. Running `kubectl` through
> `vagrant ssh k3s-master -c "sudo k3s kubectl ..."` avoids that entirely.

## 3. Pod autoscaling demo

The chat Deployment starts with one replica. The HPA reads CPU utilization from
`metrics-server` (included with k3s) and can grow it to three replicas:

- CPU request per chat pod: `100m`
- HPA target: `60%` of the request (`60m` average)
- Scale up: immediately, at most two pods or 100% per 30 s
- Scale down: after a 120 s stabilization window

Check the HPA:

```bash
vagrant ssh k3s-master -c "sudo k3s kubectl get hpa chat-server"
vagrant ssh k3s-master -c "sudo k3s kubectl describe hpa chat-server"
```

The `TARGETS` column needs a moment to show a percentage. Until metrics arrive
it displays `<unknown>`.

### Generate load

The optional Job in `kubernetes/demo/load-generator.yaml` runs inside the
cluster and posts messages through the chat Service, so requests are spread
across the existing replicas. It writes to the `loadtest` room for 3 minutes.

```bash
vagrant ssh k3s-master -c "sudo k3s kubectl apply -f /vagrant/kubernetes/demo/load-generator.yaml"

# Watch the HPA and the chat pods (two commands, HPA has no app label)
vagrant ssh k3s-master -c "sudo k3s kubectl get hpa chat-server -w"
vagrant ssh k3s-master -c "sudo k3s kubectl get pods -l app=chat-server -w"
```

Expected result: the chat Deployment goes from `1` to `3` ready pods (the
scale-up policy allows up to two new pods at once), all on `k3s-worker-chat`.
The Job finishes after about 3 minutes; the HPA then scales back to one replica
after the 120 s scale-down window.

Delete the Job and the demo data when you are done:

```bash
vagrant ssh k3s-master -c "sudo k3s kubectl delete job chat-loadgen"
vagrant ssh k3s-master -c "sudo k3s kubectl exec deploy/mariadb -- mariadb -uchat -pchatpassword chatapp -e \"DELETE FROM messages WHERE username LIKE 'load-%'; DELETE FROM rooms WHERE name='loadtest';\""
```

If CPU never crosses the target, increase `LOADGEN_WORKERS` or lower
`LOADGEN_DELAY_MS` in the Job and apply it again.

### Verify the replicas share one chat

1. Open two browser windows at <http://localhost:8080/> with different
   nicknames. New WebSocket connections are distributed across the ready pods
   by the chat Service.
2. Send messages in both directions. The message is persisted by one pod and
   delivered to the other through NATS.
3. While a client is connected, delete the pod that is serving it and check
   that the client reconnects to another replica without losing the room
   history. Use the `pod` value from the WebSocket `hello` event (or
   `nats.pod` from `/api/health`) as the pod name:
   ```bash
   vagrant ssh k3s-master -c "sudo k3s kubectl get pods -l app=chat-server -o wide"
   vagrant ssh k3s-master -c "sudo k3s kubectl delete pod chat-server-xxxxxxxxx-yyyyy"
   ```
   The pod shuts down gracefully: it closes its WebSockets with code `1001`,
   publishes an empty presence snapshot so the other replicas drop its users,
   and the browser reconnects with exponential backoff.
   Do not use `kubectl scale` to test this while the HPA is active: the HPA owns
   the replica count and will undo a manual scale.
4. Use `POD_NAME` in `/api/health` → `nats.pod` or the `pod` field in the
   WebSocket `hello` event to see which replica served a connection.

### Metrics

Each chat pod exposes Prometheus metrics on an internal-only port `9091`:

- `cda_chat_ws_connections`
- `cda_chat_ws_connections_accepted_total`
- `cda_chat_messages_persisted_total`
- `cda_chat_rooms_local`
- `cda_chat_presence_remote_pods`
- `cda_chat_nats_connected`
- `cda_chat_nats_reconnects_total`
- `cda_chat_process_cpu_seconds_total`

The port is not in the chat Service and nginx never proxies it. Prometheus
discovers chat pods through the `prometheus.io/scrape` annotations and scrapes
`/metrics` directly. To inspect one pod from the host:

```bash
vagrant ssh k3s-master -c "sudo k3s kubectl port-forward deploy/chat-server 9091:9091"
# in another terminal
curl http://localhost:9091/metrics
```

The HPA uses `metrics-server` CPU metrics, not these custom metrics. The custom
metrics are there so the same demo can be extended with Prometheus Adapter or
KEDA later. Grafana is already wired to Prometheus if you want to chart them.

## 4. Open the app

| Service | URL |
| --- | --- |
| Chat web UI | <http://localhost:8080/> |
| Grafana | <http://localhost:8080/grafana/> |
| Chat health (direct) | <http://localhost:8080/api/health> |

Grafana runs with `GF_SERVER_SERVE_FROM_SUB_PATH=true`, so nginx forwards the
`/grafana/` prefix unchanged and Grafana's `root_url` includes the browser-facing
port (`8080`). Both forms work and keep the port:

```text
/grafana/  -> 302 Location: /grafana/login
/grafana   -> 301 Location: http://localhost:8080/grafana/
```

If you change `kubernetes/nginx-configmap.yaml` or `nginx/default.conf`, apply
the ConfigMap and restart nginx so it reloads the mounted file:

```bash
vagrant ssh k3s-master -c "sudo k3s kubectl apply -f /vagrant/kubernetes/"
vagrant ssh k3s-master -c "sudo k3s kubectl rollout restart deployment/nginx-router"
```

Open the chat in two browser windows to see WebSocket messages and presence
updates in real time.

### Icons and profile colors

Click the avatar next to **Your nickname** to open the icon picker. Pick an
emoji and a background color, then **Save**. The choice is stored per nickname
in MariaDB and is broadcast over WebSocket, so every client shows the same icon
in the message list and the presence bar. **Use initials** clears the custom
icon and falls back to the generated initials and hash color.

## Local development (without Kubernetes)

You only need Node.js 20+, a MariaDB instance and a NATS server. The app starts
even if NATS is not reachable, but only local WebSocket fan-out works and
`/api/ready` stays `503`.

```bash
# Start MariaDB with the same database/user the manifests create
docker run --rm --name cda-mariadb \
  -e MYSQL_ROOT_PASSWORD=secretpassword-owo \
  -e MYSQL_DATABASE=chatapp \
  -e MYSQL_USER=chat \
  -e MYSQL_PASSWORD=chatpassword \
  -p 3306:3306 mariadb:11.4

# Start the same event bus used in Kubernetes
docker run --rm --name cda-nats -p 4222:4222 nats:2.10-alpine

cd src/chat-server
npm install
npm run check     # syntax-check every JS file

# Linux/macOS
PORT=3000 NATS_URL=nats://127.0.0.1:4222 npm start

# Windows PowerShell
$env:PORT=3000; $env:NATS_URL="nats://127.0.0.1:4222"; npm start
```

Open <http://localhost:3000>. The server creates the `rooms`, `messages` and
`profiles` tables on startup and retries every few seconds until MariaDB is
reachable. The HTTP server starts immediately, so the UI is available even
while the database is still booting (`/api/health` returns `503` until it is
ready).

## REST API

All responses are JSON. Validation errors use
`{"error":{"code":"...","message":"..."}}`.

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/api/livez` | Process liveness, always `200` while the server runs |
| `GET` | `/api/health` | Dependency details; `200` when MariaDB is reachable, `503` otherwise |
| `GET` | `/api/ready` | Kubernetes readiness; `200` only when MariaDB and NATS are both usable |
| `GET` | `/api/rooms` | Rooms with message counts and last activity |
| `POST` | `/api/rooms` | Create a room: `{"name":"random"}` |
| `GET` | `/api/messages?room=general&limit=50&before=123` | Newest messages (ascending order), optional pagination by id |
| `POST` | `/api/messages` | Persist and broadcast: `{"room":"general","username":"ada","body":"hi"}` |
| `GET` | `/api/profile?username=ada` | Stored icon/color for a nickname, or `{"profile":null}` |
| `PUT` | `/api/profile` | Save icon/color: `{"username":"ada","avatar":"🦊","color":"#7c5cff"}` |

Messages include `avatar` and `avatarColor` (empty strings when the nickname has
no custom profile). `avatar` is a short emoji/symbol (up to 8 code points) and
`color` is a `#rrggbb` hex string.

`/api/health` also reports the local realtime client count and the NATS
connection state. `/api/ready` is the probe used by Kubernetes: it returns
`503` until both MariaDB and NATS are reachable, so a replica never joins the
Service while it cannot participate in cross-pod chat.

The Prometheus endpoint is separate: `GET :9091/metrics` on each pod. It is not
mounted under `/api`, not exposed by `chat-server-service`, and not proxied by
nginx.

The API is also mounted without the `/api` prefix (for example `/health`),
which keeps direct access to the pod and the nginx proxy interchangeable.

Examples (PowerShell users should use `curl.exe`):

```bash
curl http://localhost:8080/api/health
curl "http://localhost:8080/api/messages?room=general&limit=20"
curl -X POST http://localhost:8080/api/messages \
  -H "Content-Type: application/json" \
  -d '{"room":"general","username":"ada","body":"hello from REST"}'
```

### WebSocket protocol

Connect to `ws://<host>/ws/` (or `wss://` behind TLS). Messages are JSON
objects. The server pings clients every 30 seconds and drops dead sockets.
Each event is persisted once by the pod that accepted it, then published through
NATS to every replica. Presence is a union of the local sockets on each pod, so
the presence bar is cluster-wide rather than per-pod.

Client to server:

| Type | Payload | Notes |
| --- | --- | --- |
| `join` | `{ "type":"join", "room":"general", "username":"ada", "avatar":"🦊", "color":"#7c5cff" }` | Required before sending; `avatar`/`color` are optional |
| `message` | `{ "type":"message", "room":"general", "body":"hi" }` | Uses the joined username; broadcasts to the room |
| `typing` | `{ "type":"typing" }` | Optional presence hint, throttled by the server |
| `ping` | `{ "type":"ping" }` | App-level keepalive |

Server to client:

| Type | Payload |
| --- | --- |
| `hello` | `{ clientId, serverTime, pod, limits }` |
| `joined` | `{ room, username }` |
| `message` | `{ message: { id, room, username, avatar, avatarColor, body, createdAt } }` |
| `presence` | `{ room, users: ["ada", "grace"], profiles: { ada: { avatar, color } } }` |
| `profile` | `{ profile: { username, avatar, color } }` broadcast when someone saves an icon |
| `typing` | `{ room, username }` |
| `pong` | `{ serverTime, pod }` |
| `error` | `{ code, message }` |

## Configuration

The server reads these environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | `8080` | HTTP/WebSocket port |
| `HOST` | `0.0.0.0` | Bind address |
| `METRICS_PORT` | `9091` | Internal Prometheus metrics port |
| `NATS_URL` | `nats://127.0.0.1:4222` | NATS server (`nats://nats-service:4222` in k8s) |
| `NATS_RECONNECT_MS` | `2000` | Delay between NATS reconnect attempts |
| `PRESENCE_TTL_MS` | `30000` | Drop presence from a pod that stopped sending heartbeats |
| `DB_HOST` | `127.0.0.1` | MariaDB host (`mariadb-service` in k8s) |
| `DB_PORT` | `3306` | MariaDB port |
| `DB_NAME` | `chatapp` | Database name |
| `DB_USER` | `chat` | Database user |
| `DB_PASSWORD` | `chatpassword` | Database password |
| `DB_POOL_SIZE` | `10` | Connection pool size |
| `DB_RETRY_MS` | `3000` | Schema/connection retry interval |
| `HISTORY_LIMIT` | `50` | Default messages returned by `/api/messages` |
| `MAX_MESSAGE_LENGTH` | `2000` | Maximum message size |
| `MAX_USERNAME_LENGTH` | `32` | Maximum nickname length |
| `MAX_ROOM_LENGTH` | `64` | Maximum room name length |

Kubernetes credentials live in the `chat-db-credentials` Secret (demo values).
Change them in `kubernetes/cluster-manifests.yaml` for anything beyond the lab.

## Database

Tables are created automatically. In Kubernetes the `mariadb-init` ConfigMap
is mounted at `/docker-entrypoint-initdb.d/` and executed by the official
MariaDB entrypoint the first time the pod starts against an empty
`mariadb-data` volume:

- `rooms(id, name UNIQUE, created_at)`
- `messages(id, room_id FK, username, body, created_at)` with an index on
  `(room_id, id)` for history queries, plus the seeded `general` room
- `profiles(username PK, avatar, color, updated_at)` for the custom icons and
  background colors chosen in the web UI

The same statements (all `CREATE TABLE IF NOT EXISTS` / idempotent) also live
in `src/chat-server/lib/db.js` as a fallback for local development and for
databases that were not initialized by the manifest. Keep both copies in sync.

MariaDB data is stored on the `mariadb-data` PVC. To wipe it and start fresh
(this deletes all messages and re-runs the init script on the next boot):

```bash
vagrant ssh k3s-master -c "sudo k3s kubectl delete deployment mariadb"
vagrant ssh k3s-master -c "sudo k3s kubectl delete pvc mariadb-data"
vagrant ssh k3s-master -c "sudo k3s kubectl apply -f /vagrant/kubernetes/"
```

Confirm the script ran:

```bash
vagrant ssh k3s-master -c "sudo k3s kubectl logs deploy/mariadb | grep -iE 'initdb|01-schema'"
vagrant ssh k3s-master -c "sudo k3s kubectl exec deploy/mariadb -- mariadb -uchat -pchatpassword chatapp -e 'SHOW TABLES'"
```

## Design notes and limits

- **No authentication.** Nicknames are self-asserted; this is a lab project,
  not a production messenger. Put it behind auth before exposing it.
- **Multiple chat replicas.** The WebSocket sockets are still process-local:
  each pod only knows the clients it accepted. NATS is the shared bus for
  messages, typing, profile updates and presence snapshots. Messages are
  written to MariaDB once by the accepting pod and then published to every
  replica. Presence snapshots are heartbeated every 5 seconds and expire after
  30 seconds if a pod disappears without a graceful shutdown.
- **At-most-once bus.** Plain NATS core subjects are used, not JetStream. A
  message that is persisted but lost in the bus would still be in MariaDB
  history; it just would not be pushed live. That trade-off is fine for this
  lab. Use JetStream if you need replay or delivery guarantees.
- **Pod autoscaling, not node autoscaling.** The HPA scales the chat Deployment
  between one and three pods based on CPU. All replicas land on
  `k3s-worker-chat`, which has the preloaded image and enough CPU/memory for
  the demo. Vagrant/VirtualBox nodes are static; nothing creates new VMs.
- **Fixed edge and stateful pods.** nginx, MariaDB, NATS, Prometheus and
  Grafana keep `replicas: 1` and node selectors. They are not part of the HPA.
- **Image distribution.** There is no registry. If you add another autoscaling
  worker, preload `images/chat-server.tar` there too, or the new replicas will
  stay in `ErrImagePull`.
- **Database connections.** Each chat pod uses a pool of five connections, so
  three replicas stay well inside MariaDB's default connection limit.
- **Abuse limits.** 400 ms between messages per socket, 64 KB WebSocket
  frames, 64 KB JSON request bodies, 2000-character messages.
- **Readiness.** Kubernetes probes `/api/ready` and only sends traffic to
  replicas that can reach both MariaDB and NATS. `/api/livez` remains the
  liveness probe, so the process is not restarted just because a dependency is
  temporarily down. `/api/health` reports the full dependency state for humans
  and monitoring.
- **Worker memory.** The db worker and the monitoring worker are bumped to 1 GB
  in the Vagrantfile, and the app worker to 1.5 GB with 1 vCPU, so the fixed
  services and the autoscaled chat replicas fit comfortably. The app worker is
  deliberately single-vCPU because this guest hangs at boot with 2 vCPUs when
  VirtualBox falls back to NEM on a Hyper-V host.
- **Multi-NIC nodes.** Every VirtualBox VM gets the same NAT address
  (`10.0.2.15`), so k3s pins the node IP and Flannel to the host-only network
  (`192.168.56.0/24`, interface `enp0s8`). Without this the nodes report
  `Ready` but pod traffic between nodes is sent to the wrong host.
