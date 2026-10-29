import { randomUUID } from 'node:crypto';
import { WebSocket, WebSocketServer } from 'ws';
import { config } from './config.js';
import { createEventBus } from './bus.js';
import { createMessage } from './store.js';
import { HttpError, normalizeAvatar, normalizeAvatarColor, normalizeBody, normalizeRoom, normalizeUsername } from './validation.js';

const ALLOWED_PATHS = new Set(['/', '/ws', '/ws/']);
const MIN_MESSAGE_INTERVAL_MS = 400;
const MIN_TYPING_INTERVAL_MS = 1000;
const PRESENCE_HEARTBEAT_MS = 5_000;
const PRESENCE_SWEEP_MS = 10_000;
const SHUTDOWN_GRACE_MS = 250;

function send(socket, payload) {
  if (socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify(payload));
  }
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function errorPayload(error) {
  if (error instanceof HttpError) {
    return { type: 'error', code: error.code, message: error.message };
  }

  return {
    type: 'error',
    code: 'database_unavailable',
    message: 'The database is unavailable right now. Please try again shortly.',
  };
}

export function createRealtimeHub(server) {
  const wss = new WebSocketServer({
    noServer: true,
    clientTracking: true,
    maxPayload: 64 * 1024,
  });

  // Only the sockets connected to THIS pod are stored here. NATS carries the
  // events between replicas.
  const clients = new Set();

  // podId -> Map(room -> { users, profiles, updatedAt })
  const remotePresence = new Map();
  const counters = {
    connections: 0,
    messages: 0,
    profiles: 0,
  };

  const bus = createEventBus({
    handlers: {
      onMessage(message) {
        broadcast(message.room, { type: 'message', message });
      },

      onTyping({ room, username, excludeClientId }) {
        broadcastOthersById(room, excludeClientId, { type: 'typing', room, username });
      },

      onPresence(snapshot) {
        applyRemotePresence(snapshot);
      },

      onProfile(profile) {
        applyProfile(profile);
      },
    },
  });

  server.on('upgrade', (request, socket, head) => {
    let pathname;

    try {
      pathname = new URL(request.url, 'http://localhost').pathname;
    } catch {
      socket.destroy();
      return;
    }

    if (!ALLOWED_PATHS.has(pathname)) {
      socket.write('HTTP/1.1 404 Not Found\r\n\r\n');
      socket.destroy();
      return;
    }

    wss.handleUpgrade(request, socket, head, (ws) => {
      wss.emit('connection', ws, request);
    });
  });

  function broadcast(room, payload) {
    const data = JSON.stringify(payload);

    for (const client of clients) {
      if (client.meta.room === room && client.readyState === WebSocket.OPEN) {
        client.send(data);
      }
    }
  }

  function broadcastOthersById(room, excludeClientId, payload) {
    const data = JSON.stringify(payload);

    for (const client of clients) {
      if (client.meta.id === excludeClientId) continue;
      if (client.meta.room === room && client.readyState === WebSocket.OPEN) {
        client.send(data);
      }
    }
  }

  function broadcastAll(payload) {
    const data = JSON.stringify(payload);

    for (const client of clients) {
      if (client.readyState === WebSocket.OPEN) {
        client.send(data);
      }
    }
  }

  function localPresence(room) {
    const users = new Set();
    const profiles = {};

    for (const client of clients) {
      if (client.meta.room === room && client.meta.username) {
        users.add(client.meta.username);
        profiles[client.meta.username] = {
          avatar: client.meta.avatar || '',
          color: client.meta.color || '',
        };
      }
    }

    return {
      users: [...users].sort((a, b) => a.localeCompare(b)),
      profiles,
    };
  }

  function presenceFor(room) {
    const users = new Set();
    const profiles = {};
    const local = localPresence(room);

    for (const username of local.users) {
      users.add(username);
      profiles[username] = local.profiles[username];
    }

    for (const rooms of remotePresence.values()) {
      const snapshot = rooms.get(room);
      if (!snapshot) continue;

      for (const username of snapshot.users) {
        users.add(username);
        profiles[username] = snapshot.profiles[username] || { avatar: '', color: '' };
      }
    }

    return {
      users: [...users].sort((a, b) => a.localeCompare(b)),
      profiles,
    };
  }

  function broadcastPresence(room) {
    if (!room) return;
    broadcast(room, { type: 'presence', room, ...presenceFor(room) });
  }

  function publishLocalPresence(room) {
    if (!room) return;

    // Local clients should update immediately, even if NATS is unavailable.
    broadcastPresence(room);

    // Publish the snapshot for the other replicas. Empty snapshots are useful:
    // they tell the other pods that this pod no longer hosts users in the room.
    bus.publishPresence({
      room,
      ...localPresence(room),
    });
  }

  function applyRemotePresence({ podId, room, users, profiles }) {
    if (!podId || podId === bus.podId) return;

    let rooms = remotePresence.get(podId);
    if (users.length === 0) {
      if (rooms) {
        rooms.delete(room);
        if (rooms.size === 0) remotePresence.delete(podId);
      }
      broadcastPresence(room);
      return;
    }

    if (!rooms) {
      rooms = new Map();
      remotePresence.set(podId, rooms);
    }

    rooms.set(room, {
      users,
      profiles,
      updatedAt: Date.now(),
    });

    broadcastPresence(room);
  }

  function applyProfile(profile) {
    counters.profiles += 1;

    for (const client of clients) {
      if (client.meta.username !== profile.username) continue;
      client.meta.avatar = profile.avatar || '';
      client.meta.color = profile.color || '';
    }

    broadcastAll({ type: 'profile', profile });

    // Refresh presence snapshots so a newly connected client sees the new
    // avatar even before the next profile event arrives.
    const rooms = new Set();
    for (const client of clients) {
      if (client.meta.username === profile.username && client.meta.room) {
        rooms.add(client.meta.room);
      }
    }
    for (const room of rooms) {
      publishLocalPresence(room);
    }
  }

  function publishMessage(message) {
    counters.messages += 1;

    // If NATS is down, a single pod can still fan out locally. Once NATS is
    // back, the event is delivered to every replica as usual.
    if (!bus.publishMessage(message)) {
      broadcast(message.room, { type: 'message', message });
    }
  }

  function joinRoom(socket, { room, username, avatar, color }) {
    const normalizedRoom = normalizeRoom(room);
    const normalizedUsername = normalizeUsername(username);
    const previousRoom = socket.meta.room;
    const previousUsername = socket.meta.username;

    socket.meta.room = normalizedRoom;
    socket.meta.username = normalizedUsername;
    if (avatar !== undefined) socket.meta.avatar = avatar;
    if (color !== undefined) socket.meta.color = color;

    if (previousRoom && (previousRoom !== normalizedRoom || previousUsername !== normalizedUsername)) {
      publishLocalPresence(previousRoom);
    }

    send(socket, {
      type: 'joined',
      room: normalizedRoom,
      username: normalizedUsername,
    });
    publishLocalPresence(normalizedRoom);
  }

  wss.on('connection', (socket) => {
    counters.connections += 1;
    socket.meta = {
      id: randomUUID(),
      room: null,
      username: null,
      avatar: '',
      color: '',
      alive: true,
      lastMessageAt: 0,
      lastTypingAt: 0,
    };
    clients.add(socket);

    send(socket, {
      type: 'hello',
      clientId: socket.meta.id,
      serverTime: new Date().toISOString(),
      pod: bus.podId,
      limits: config.limits,
    });

    socket.on('pong', () => {
      socket.meta.alive = true;
    });

    socket.on('message', async (raw) => {
      let payload;

      try {
        payload = JSON.parse(raw.toString());
      } catch {
        send(socket, { type: 'error', code: 'bad_json', message: 'Messages must be valid JSON.' });
        return;
      }

      if (!payload || typeof payload !== 'object') {
        send(socket, { type: 'error', code: 'bad_request', message: 'Invalid message format.' });
        return;
      }

      try {
        switch (payload.type) {
          case 'join': {
            joinRoom(socket, {
              room: payload.room ?? socket.meta.room ?? 'general',
              username: payload.username ?? socket.meta.username,
              avatar: payload.avatar === undefined ? undefined : normalizeAvatar(payload.avatar),
              color: payload.color === undefined ? undefined : normalizeAvatarColor(payload.color),
            });
            break;
          }

          case 'message': {
            const room = normalizeRoom(payload.room ?? socket.meta.room, { fallback: 'general' });
            const username = payload.username
              ? normalizeUsername(payload.username)
              : socket.meta.username;

            if (!username) {
              throw new HttpError(400, 'Set a username before sending messages.');
            }
            if (socket.meta.room !== room || socket.meta.username !== username) {
              joinRoom(socket, { room, username });
            }

            const now = Date.now();
            const body = normalizeBody(payload.body);

            if (now - socket.meta.lastMessageAt < MIN_MESSAGE_INTERVAL_MS) {
              throw new HttpError(429, 'You are sending messages too quickly.', 'rate_limited');
            }
            socket.meta.lastMessageAt = now;

            const message = await createMessage({
              room,
              username,
              body,
            });

            publishMessage(message);
            break;
          }

          case 'typing': {
            if (!socket.meta.room || !socket.meta.username) break;

            const now = Date.now();
            if (now - socket.meta.lastTypingAt < MIN_TYPING_INTERVAL_MS) break;
            socket.meta.lastTypingAt = now;

            const typing = {
              room: socket.meta.room,
              username: socket.meta.username,
              excludeClientId: socket.meta.id,
            };

            if (!bus.publishTyping(typing)) {
              broadcastOthersById(typing.room, typing.excludeClientId, {
                type: 'typing',
                room: typing.room,
                username: typing.username,
              });
            }
            break;
          }

          case 'ping':
            send(socket, { type: 'pong', serverTime: new Date().toISOString(), pod: bus.podId });
            break;

          default:
            send(socket, {
              type: 'error',
              code: 'unknown_type',
              message: `Unknown message type: ${String(payload.type)}`,
            });
        }
      } catch (error) {
        if (!(error instanceof HttpError)) {
          console.error('[ws] failed to handle message:', error);
        }
        send(socket, errorPayload(error));
      }
    });

    socket.on('close', () => {
      clients.delete(socket);
      publishLocalPresence(socket.meta.room);
    });

    socket.on('error', (error) => {
      console.error('[ws] socket error:', error.message);
    });
  });

  // Drop connections that stopped answering protocol pings.
  const heartbeat = setInterval(() => {
    for (const client of clients) {
      if (client.meta.alive === false) {
        client.terminate();
        continue;
      }

      client.meta.alive = false;
      try {
        client.ping();
      } catch {
        client.terminate();
      }
    }
  }, 30_000);
  heartbeat.unref();

  // Presence snapshots are only sent when something changes. This heartbeat
  // lets pods that started later discover the existing users, and refreshes the
  // TTL used below for pods that disappear without a graceful shutdown.
  const presenceHeartbeat = setInterval(() => {
    const rooms = new Set();
    for (const client of clients) {
      if (client.meta.room) rooms.add(client.meta.room);
    }

    for (const room of rooms) {
      bus.publishPresence({
        room,
        ...localPresence(room),
      });
    }
  }, PRESENCE_HEARTBEAT_MS);
  presenceHeartbeat.unref();

  const presenceSweep = setInterval(() => {
    const now = Date.now();
    const changedRooms = new Set();

    for (const [podId, rooms] of remotePresence) {
      for (const [room, snapshot] of rooms) {
        if (now - snapshot.updatedAt <= config.nats.presenceTtlMs) continue;
        rooms.delete(room);
        changedRooms.add(room);
      }

      if (rooms.size === 0) remotePresence.delete(podId);
    }

    for (const room of changedRooms) {
      broadcastPresence(room);
    }
  }, PRESENCE_SWEEP_MS);
  presenceSweep.unref();

  bus.start().catch((error) => {
    console.error('[nats] background connection stopped:', error);
  });

  return {
    broadcastMessage(message) {
      publishMessage(message);
    },

    broadcastProfile(profile) {
      if (!bus.publishProfile(profile)) {
        applyProfile(profile);
      }
    },

    stats() {
      const rooms = new Set();
      for (const client of clients) {
        if (client.meta.room) rooms.add(client.meta.room);
      }

      return {
        clients: clients.size,
        rooms: [...rooms],
        remotePods: remotePresence.size,
        connectionsAccepted: counters.connections,
        messagesPersisted: counters.messages,
        profileUpdates: counters.profiles,
      };
    },

    busStatus() {
      return bus.status();
    },

    metrics() {
      const rooms = new Set();
      for (const client of clients) {
        if (client.meta.room) rooms.add(client.meta.room);
      }

      return {
        clients: clients.size,
        rooms: rooms.size,
        remotePods: remotePresence.size,
        connectionsAccepted: counters.connections,
        messagesPersisted: counters.messages,
        profileUpdates: counters.profiles,
        natsConnected: bus.isConnected() ? 1 : 0,
        natsReconnects: bus.status().reconnects,
      };
    },

    async close() {
      clearInterval(heartbeat);
      clearInterval(presenceHeartbeat);
      clearInterval(presenceSweep);

      // Let the other replicas remove this pod's users immediately instead of
      // waiting for the presence TTL.
      const rooms = new Set();
      for (const client of clients) {
        if (client.meta.room) rooms.add(client.meta.room);
      }
      for (const room of rooms) {
        bus.publishPresence({ room, users: [], profiles: {} });
      }

      for (const client of clients) {
        try {
          client.close(1001, 'Server shutting down');
        } catch {
          client.terminate();
        }
      }

      await delay(SHUTDOWN_GRACE_MS);

      for (const client of clients) {
        client.terminate();
      }
      clients.clear();

      await new Promise((resolve) => wss.close(resolve));
      await bus.close();
    },
  };
}
