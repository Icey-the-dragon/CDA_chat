# CDA Chat

A five-node Vagrant + k3s lab that runs MariaDB, a lightweight Node.js chat
server, Prometheus, Grafana and an nginx router.

The chat server serves three things from one process on port `8080`:

- **REST API** under `/api`
- **WebSocket** live chat under `/ws/`
- **Web UI** (plain HTML/CSS/JS, no build step) at `/`


```
Browser ──► localhost:8080
              │
              ▼
        nginx-router (:80, NodePort 30080)
              ├── /            ──► chat-server-service:8080  (web UI)
              ├── /api/        ──► chat-server-service:8080  (REST)
              ├── /ws/         ──► chat-server-service:8080  (WebSocket)
              └── /grafana/    ──► grafana-service:3000
                                        │
        chat-server ────────────────────┘
              └── mariadb-service:3306 ──► MariaDB (db worker, PVC)
```

## Repository layout

```
kubernetes/
  cluster-manifests.yaml   Secret, MariaDB schema init, MariaDB + chat + Prometheus + Grafana + nginx
  nginx-configmap.yaml     nginx config mounted into the nginx pod
nginx/default.conf         source copy of the nginx config
src/chat-server/
  server.js                HTTP + WebSocket bootstrap
  lib/                     config, MariaDB access, REST routes, realtime hub
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

The master applies everything in `kubernetes/` after it boots. The chat pod is
pinned to the `role=chat` worker; build the image on the host before
`vagrant up` so that worker can preload it from the synced folder (next step).

MariaDB creates the `chatapp` database and runs the initial schema from the
`mariadb-init` ConfigMap on first boot (empty PVC). This only happens once:
restarting the pod does not recreate tables or wipe messages.

## 2. Build and load the chat image

The chat pod is pinned to the `role=chat` worker, so only `k3s-worker-chat`
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
the chat pod stays in `ErrImagePull`.

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

## 3. Open the app

| Service | URL |
| --- | --- |
| Chat web UI | <http://localhost:8080/> |
| Grafana | <http://localhost:8080/grafana/> |
| Chat health (direct) | <http://localhost:8080/api/health> |

Open the chat in two browser windows to see WebSocket messages and presence
updates in real time.

### Icons and profile colors

Click the avatar next to **Your nickname** to open the icon picker. Pick an
emoji and a background color, then **Save**. The choice is stored per nickname
in MariaDB and is broadcast over WebSocket, so every client shows the same icon
in the message list and the presence bar. **Use initials** clears the custom
icon and falls back to the generated initials and hash color.

## Local development (without Kubernetes)

You only need Node.js 20+ and a MariaDB instance.

```bash
# Start MariaDB with the same database/user the manifests create
docker run --rm --name cda-mariadb \
  -e MYSQL_ROOT_PASSWORD=secretpassword-owo \
  -e MYSQL_DATABASE=chatapp \
  -e MYSQL_USER=chat \
  -e MYSQL_PASSWORD=chatpassword \
  -p 3306:3306 mariadb:11.4

cd src/chat-server
npm install
npm run check     # syntax-check every JS file

# Linux/macOS
PORT=3000 npm start

# Windows PowerShell
$env:PORT=3000; npm start
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
| `GET` | `/api/health` | `200` when MariaDB is reachable, `503` otherwise |
| `GET` | `/api/rooms` | Rooms with message counts and last activity |
| `POST` | `/api/rooms` | Create a room: `{"name":"random"}` |
| `GET` | `/api/messages?room=general&limit=50&before=123` | Newest messages (ascending order), optional pagination by id |
| `POST` | `/api/messages` | Persist and broadcast: `{"room":"general","username":"ada","body":"hi"}` |
| `GET` | `/api/profile?username=ada` | Stored icon/color for a nickname, or `{"profile":null}` |
| `PUT` | `/api/profile` | Save icon/color: `{"username":"ada","avatar":"🦊","color":"#7c5cff"}` |

Messages include `avatar` and `avatarColor` (empty strings when the nickname has
no custom profile). `avatar` is a short emoji/symbol (up to 8 code points) and
`color` is a `#rrggbb` hex string.

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
| `hello` | `{ clientId, serverTime, limits }` |
| `joined` | `{ room, username }` |
| `message` | `{ message: { id, room, username, avatar, avatarColor, body, createdAt } }` |
| `presence` | `{ room, users: ["ada", "grace"], profiles: { ada: { avatar, color } } }` |
| `profile` | `{ profile: { username, avatar, color } }` broadcast when someone saves an icon |
| `typing` | `{ room, username }` |
| `pong` | `{ serverTime }` |
| `error` | `{ code, message }` |

## Configuration

The server reads these environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | `8080` | HTTP/WebSocket port |
| `HOST` | `0.0.0.0` | Bind address |
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
- **Single chat replica.** The WebSocket hub lives in process memory. With
  more than one replica, clients on different pods would not receive each
  other's broadcasts without a shared pub/sub layer (Redis, NATS, etc.).
- **Abuse limits.** 400 ms between messages per socket, 64 KB WebSocket
  frames, 64 KB JSON request bodies, 2000-character messages.
- **Readiness.** Kubernetes probes `/api/livez` so the UI stays reachable and
  can display database errors; `/api/health` reports the dependency state for
  humans and monitoring.
- **Worker memory.** The db worker is bumped to 1 GB in the Vagrantfile
  because MariaDB plus the k3s agent does not fit comfortably in 512 MB.
- **Multi-NIC nodes.** Every VirtualBox VM gets the same NAT address
  (`10.0.2.15`), so k3s pins the node IP and Flannel to the host-only network
  (`192.168.56.0/24`, interface `enp0s8`). Without this the nodes report
  `Ready` but pod traffic between nodes is sent to the wrong host.
