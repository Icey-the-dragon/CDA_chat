import { Events, JSONCodec, connect } from 'nats';
import { config } from './config.js';

// Every chat pod uses NATS as a small event bus. The WebSocket clients stay
// local to the pod that accepted them; NATS forwards room messages, typing
// hints, presence snapshots and profile updates to every replica.
const PREFIX = 'cda.chat';
const codec = JSONCodec();

export const POD_ID = process.env.POD_NAME || process.env.HOSTNAME || `local-${process.pid}`;

const SUBJECTS = {
  message: `${PREFIX}.room.*.message`,
  typing: `${PREFIX}.room.*.typing`,
  presence: `${PREFIX}.room.*.presence`,
  profile: `${PREFIX}.profile`,
};

function roomFromSubject(subject, type) {
  const parts = subject.split('.');
  if (
    parts.length !== 5
    || parts[0] !== 'cda'
    || parts[1] !== 'chat'
    || parts[2] !== 'room'
    || parts[4] !== type
  ) {
    return null;
  }

  return parts[3];
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function decode(data) {
  try {
    return codec.decode(data);
  } catch {
    return null;
  }
}

/**
 * Creates a lazy NATS client. It starts retrying in the background so the HTTP
 * server can accept traffic before NATS (or the whole cluster) is ready.
 */
export function createEventBus({ handlers = {} } = {}) {
  let nc = null;
  let connected = false;
  let closed = false;
  let starting = null;
  let lastError = null;
  let reconnects = 0;
  let server = null;

  function callHandler(name, payload) {
    const handler = handlers[name];
    if (typeof handler !== 'function') return;

    try {
      const result = handler(payload);
      if (result && typeof result.catch === 'function') {
        result.catch((error) => console.error(`[nats] ${name} handler failed:`, error));
      }
    } catch (error) {
      console.error(`[nats] ${name} handler failed:`, error);
    }
  }

  function isConnected() {
    return connected && Boolean(nc) && !nc.isClosed();
  }

  async function subscribeAll(client) {
    // nats.js expects the callback inside the options object; passing a function
    // as the second argument creates an iterator subscription that is never
    // consumed, so no handler would ever fire.
    client.subscribe(SUBJECTS.message, {
      callback: (error, message) => {
        if (error) return;
        const room = roomFromSubject(message.subject, 'message');
        const payload = decode(message.data);
        if (!room || !payload?.message || payload.message.room !== room) return;
        callHandler('onMessage', payload.message);
      },
    });

    client.subscribe(SUBJECTS.typing, {
      callback: (error, message) => {
        if (error) return;
        const room = roomFromSubject(message.subject, 'typing');
        const payload = decode(message.data);
        if (!room || typeof payload?.username !== 'string') return;
        callHandler('onTyping', {
          room,
          username: payload.username,
          excludeClientId: typeof payload.excludeClientId === 'string' ? payload.excludeClientId : null,
        });
      },
    });

    client.subscribe(SUBJECTS.presence, {
      callback: (error, message) => {
        if (error) return;
        const room = roomFromSubject(message.subject, 'presence');
        const payload = decode(message.data);
        if (!room || typeof payload?.podId !== 'string' || payload.podId === POD_ID) return;

        callHandler('onPresence', {
          podId: payload.podId,
          room,
          users: Array.isArray(payload.users)
            ? payload.users.filter((user) => typeof user === 'string')
            : [],
          profiles: payload.profiles && typeof payload.profiles === 'object'
            ? payload.profiles
            : {},
        });
      },
    });

    client.subscribe(SUBJECTS.profile, {
      callback: (error, message) => {
        if (error) return;
        const payload = decode(message.data);
        if (!payload?.profile || typeof payload.profile.username !== 'string') return;
        callHandler('onProfile', payload.profile);
      },
    });

    await client.flush();
  }

  async function connectOnce() {
    return connect({
      servers: config.nats.url,
      name: `chat-server-${POD_ID}`,
      reconnect: true,
      maxReconnectAttempts: -1,
      reconnectTimeWait: config.nats.reconnectMs,
      // Let the initial attempt fail so the retry loop below can observe
      // `closed` and exit. After the first connection, nats.js reconnects
      // internally forever.
      pingInterval: 10_000,
      maxPingOut: 3,
      timeout: 5_000,
    });
  }

  async function watchStatus(client) {
    try {
      for await (const status of client.status()) {
        switch (status.type) {
          case Events.Disconnect:
            connected = false;
            console.warn('[nats] disconnected; retrying in the background');
            break;

          case Events.Reconnect:
            connected = true;
            reconnects += 1;
            server = client.getServer();
            console.log(`[nats] reconnected to ${server} (${reconnects} reconnects)`);
            break;

          case Events.Error:
            lastError = status.data instanceof Error
              ? status.data
              : new Error(String(status.data));
            console.error('[nats] client error:', lastError.message);
            break;

          default:
            break;
        }
      }
    } catch (error) {
      if (!closed) {
        console.error('[nats] status watcher stopped:', error.message);
      }
    }
  }

  function start() {
    if (starting) return starting;

    starting = (async () => {
      while (!closed) {
        try {
          const client = await connectOnce();
          if (closed) {
            await client.close();
            return;
          }

          nc = client;
          server = client.getServer();
          connected = true;
          lastError = null;

          await subscribeAll(client);
          watchStatus(client);
          console.log(`[nats] subscribed to ${PREFIX}.* as ${POD_ID} on ${server}`);
          return;
        } catch (error) {
          if (closed) return;
          lastError = error;
          console.error(`[nats] connection failed: ${error.message}; retrying`);
          await delay(config.nats.reconnectMs);
        }
      }
    })();

    return starting;
  }

  function publish(subject, payload) {
    if (!isConnected()) return false;

    try {
      nc.publish(subject, codec.encode(payload));
      return true;
    } catch (error) {
      lastError = error;
      console.error('[nats] publish failed:', error.message);
      return false;
    }
  }

  function publishMessage(message) {
    return publish(`${PREFIX}.room.${message.room}.message`, {
      podId: POD_ID,
      message,
    });
  }

  function publishTyping({ room, username, excludeClientId }) {
    return publish(`${PREFIX}.room.${room}.typing`, {
      podId: POD_ID,
      username,
      excludeClientId,
    });
  }

  function publishPresence({ room, users, profiles }) {
    return publish(`${PREFIX}.room.${room}.presence`, {
      podId: POD_ID,
      users,
      profiles,
      sentAt: Date.now(),
    });
  }

  function publishProfile(profile) {
    return publish(SUBJECTS.profile, {
      podId: POD_ID,
      profile,
    });
  }

  async function close() {
    closed = true;
    connected = false;

    const client = nc;
    nc = null;
    if (!client) return;

    try {
      await Promise.race([client.drain(), delay(1_000)]);
    } catch {
      // Draining is best-effort; close below always releases the socket.
    }

    try {
      await client.close();
    } catch {
      // Already closed.
    }
  }

  return {
    podId: POD_ID,
    start,
    close,
    publishMessage,
    publishTyping,
    publishPresence,
    publishProfile,
    isConnected,
    status() {
      return {
        connected: isConnected(),
        pod: POD_ID,
        server,
        reconnects,
        error: lastError ? lastError.message : null,
      };
    },
  };
}
