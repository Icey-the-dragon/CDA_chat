import { randomUUID } from 'node:crypto';
import { WebSocket, WebSocketServer } from 'ws';
import { config } from './config.js';
import { createMessage } from './store.js';
import { HttpError, normalizeBody, normalizeRoom, normalizeUsername } from './validation.js';

const ALLOWED_PATHS = new Set(['/', '/ws', '/ws/']);
const MIN_MESSAGE_INTERVAL_MS = 400;
const MIN_TYPING_INTERVAL_MS = 1000;

function send(socket, payload) {
  if (socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify(payload));
  }
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

  const clients = new Set();

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

  function broadcastOthers(sender, room, payload) {
    const data = JSON.stringify(payload);

    for (const client of clients) {
      if (client !== sender && client.meta.room === room && client.readyState === WebSocket.OPEN) {
        client.send(data);
      }
    }
  }

  function presenceFor(room) {
    const users = new Set();

    for (const client of clients) {
      if (client.meta.room === room && client.meta.username) {
        users.add(client.meta.username);
      }
    }

    return [...users].sort((a, b) => a.localeCompare(b));
  }

  function broadcastPresence(room) {
    if (!room) return;
    broadcast(room, { type: 'presence', room, users: presenceFor(room) });
  }

  function joinRoom(socket, { room, username }) {
    const normalizedRoom = normalizeRoom(room);
    const normalizedUsername = normalizeUsername(username);
    const previousRoom = socket.meta.room;
    const previousUsername = socket.meta.username;

    socket.meta.room = normalizedRoom;
    socket.meta.username = normalizedUsername;

    if (previousRoom && (previousRoom !== normalizedRoom || previousUsername !== normalizedUsername)) {
      broadcastPresence(previousRoom);
    }

    send(socket, {
      type: 'joined',
      room: normalizedRoom,
      username: normalizedUsername,
    });
    broadcastPresence(normalizedRoom);
  }

  wss.on('connection', (socket) => {
    socket.meta = {
      id: randomUUID(),
      room: null,
      username: null,
      alive: true,
      lastMessageAt: 0,
      lastTypingAt: 0,
    };
    clients.add(socket);

    send(socket, {
      type: 'hello',
      clientId: socket.meta.id,
      serverTime: new Date().toISOString(),
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

            broadcast(room, { type: 'message', message });
            break;
          }

          case 'typing': {
            if (!socket.meta.room || !socket.meta.username) break;

            const now = Date.now();
            if (now - socket.meta.lastTypingAt < MIN_TYPING_INTERVAL_MS) break;
            socket.meta.lastTypingAt = now;

            broadcastOthers(socket, socket.meta.room, {
              type: 'typing',
              room: socket.meta.room,
              username: socket.meta.username,
            });
            break;
          }

          case 'ping':
            send(socket, { type: 'pong', serverTime: new Date().toISOString() });
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
      broadcastPresence(socket.meta.room);
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

  return {
    broadcastMessage(message) {
      broadcast(message.room, { type: 'message', message });
    },

    stats() {
      const rooms = new Set();
      for (const client of clients) {
        if (client.meta.room) rooms.add(client.meta.room);
      }

      return { clients: clients.size, rooms: [...rooms] };
    },

    async close() {
      clearInterval(heartbeat);

      for (const client of clients) {
        client.terminate();
      }

      await new Promise((resolve) => wss.close(resolve));
    },
  };
}
