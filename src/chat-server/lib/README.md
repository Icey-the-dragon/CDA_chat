# `lib/` map

`server.js` stays deliberately small: it wires HTTP, static files and the four
modules below. This directory is server-side only; the React app in
`../frontend/` cannot replace it.

## Request path

```text
HTTP request -> server.js -> api.js -> store.js -> db.js -> MariaDB
                         \-> realtime.js -> bus.js -> NATS -> other chat pods
```

| File | Responsibility | Exports used by |
| --- | --- | --- |
| `config.js` | Parses environment variables into one frozen-shape `config` object. No I/O. | everything |
| `validation.js` | Normalises room/username/profile/message input and throws `HttpError`. | `api.js`, `realtime.js` |
| `db.js` | Owns the MySQL pool, schema bootstrap, health state and shutdown. | `api.js`, `store.js`, `server.js` |
| `store.js` | Only SQL queries for rooms, messages and profiles. No HTTP/WebSocket types. | `api.js`, `realtime.js` |
| `bus.js` | NATS connection, reconnect loop, subscribe/publish helpers and presence TTL. | `realtime.js` |
| `realtime.js` | WebSocket sessions, join/typing/message/presence fan-out and metrics. | `server.js`, `api.js` |
| `api.js` | Express router: `/health`, `/ready`, rooms, messages, profiles. | `server.js` |

## Invariants

- `db.js` is the **only** module that imports `mysql2`.
- `bus.js` is the **only** module that imports `nats`.
- `store.js` never touches Express or NATS; `api.js` never builds SQL.
- `server.js` is the only place that starts/stops listeners and pools.
- Keep the fallback schema in `db.js` in sync with the `mariadb-init` ConfigMap in
  `kubernetes/cluster-manifests.yaml`.

## Failure behaviour

- Database errors are translated to HTTP 503 by the error middleware in
  `server.js`; the chat process does not exit.
- NATS is optional for local development (`bus.js` retries in the background),
  but `/api/ready` reports `not_ready` until a server is reachable.
- `SIGTERM`/`SIGINT` close WebSockets, HTTP servers, NATS and the DB pool in that
  order so Kubernetes rollouts do not drop in-flight messages.
