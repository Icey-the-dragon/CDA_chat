import { fileURLToPath } from 'node:url';

function positiveInt(value, fallback) {
  const parsed = Number.parseInt(value ?? '', 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

export const config = {
  version: '1.0.0',
  host: process.env.HOST || '0.0.0.0',
  port: positiveInt(process.env.PORT, 8080),
  metricsPort: positiveInt(process.env.METRICS_PORT, 9091),
  publicDir: fileURLToPath(new URL('../public/', import.meta.url)),

  nats: {
    url: process.env.NATS_URL || 'nats://127.0.0.1:4222',
    reconnectMs: positiveInt(process.env.NATS_RECONNECT_MS, 2000),
    presenceTtlMs: positiveInt(process.env.PRESENCE_TTL_MS, 30_000),
  },

  db: {
    host: process.env.DB_HOST || '127.0.0.1',
    port: positiveInt(process.env.DB_PORT, 3306),
    user: process.env.DB_USER || 'chat',
    password: process.env.DB_PASSWORD || 'chatpassword',
    database: process.env.DB_NAME || 'chatapp',
    connectionLimit: positiveInt(process.env.DB_POOL_SIZE, 10),
    connectTimeout: positiveInt(process.env.DB_CONNECT_TIMEOUT_MS, 5000),
  },

  // How long to wait before retrying a failed database connection.
  dbRetryMs: positiveInt(process.env.DB_RETRY_MS, 3000),

  limits: {
    history: positiveInt(process.env.HISTORY_LIMIT, 50),
    message: positiveInt(process.env.MAX_MESSAGE_LENGTH, 2000),
    username: positiveInt(process.env.MAX_USERNAME_LENGTH, 32),
    room: positiveInt(process.env.MAX_ROOM_LENGTH, 64),
  },
};
