import http from 'node:http';
import path from 'node:path';
import express from 'express';
import { config } from './lib/config.js';
import { startDatabase, stopDatabase } from './lib/db.js';
import { createRealtimeHub } from './lib/realtime.js';
import { createApiRouter } from './lib/api.js';

const app = express();
app.disable('x-powered-by');
app.use((request, response, next) => {
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('Referrer-Policy', 'same-origin');
  next();
});
app.use(express.json({ limit: '64kb' }));

const DATABASE_ERROR_CODES = new Set([
  'ECONNREFUSED',
  'ECONNRESET',
  'ETIMEDOUT',
  'EPIPE',
  'PROTOCOL_CONNECTION_LOST',
  'PROTOCOL_SEQUENCE_TIMEOUT',
]);

function isDatabaseError(error) {
  return typeof error.code === 'string'
    && (error.code.startsWith('ER_') || DATABASE_ERROR_CODES.has(error.code));
}

app.use(express.static(config.publicDir, {
  etag: true,
  index: 'index.html',
}));

const server = http.createServer(app);
const hub = createRealtimeHub(server);
const api = createApiRouter({ hub });

function renderMetrics() {
  const realtime = hub.metrics();
  const nats = hub.busStatus();
  const memory = process.memoryUsage();
  const cpu = process.cpuUsage();

  const metrics = [
    ['cda_chat_ws_connections', 'gauge', 'WebSocket connections currently attached to this pod.', realtime.clients],
    ['cda_chat_ws_connections_accepted_total', 'counter', 'WebSocket connections accepted by this pod since start.', realtime.connectionsAccepted],
    ['cda_chat_messages_persisted_total', 'counter', 'Chat messages persisted by this pod since start.', realtime.messagesPersisted],
    ['cda_chat_rooms_local', 'gauge', 'Rooms with at least one local WebSocket client.', realtime.rooms],
    ['cda_chat_presence_remote_pods', 'gauge', 'Remote pods currently contributing presence snapshots.', realtime.remotePods],
    ['cda_chat_profile_updates_total', 'counter', 'Profile updates applied by this pod since start.', realtime.profileUpdates],
    ['cda_chat_nats_connected', 'gauge', 'Whether this pod is connected to NATS (1) or not (0).', realtime.natsConnected],
    ['cda_chat_nats_reconnects_total', 'counter', 'NATS reconnect count for this pod.', realtime.natsReconnects],
    ['cda_chat_uptime_seconds', 'gauge', 'Process uptime in seconds.', Math.round(process.uptime())],
    ['cda_chat_process_resident_memory_bytes', 'gauge', 'Resident memory used by this pod in bytes.', memory.rss],
    ['cda_chat_process_heap_used_bytes', 'gauge', 'V8 heap used by this pod in bytes.', memory.heapUsed],
    ['cda_chat_process_cpu_seconds_total', 'counter', 'CPU time used by this pod in seconds.', (cpu.user + cpu.system) / 1_000_000],
  ];

  const lines = [];
  for (const [name, type, help, value] of metrics) {
    lines.push(`# HELP ${name} ${help}`);
    lines.push(`# TYPE ${name} ${type}`);
    lines.push(`${name} ${value}`);
  }

  lines.push('# HELP cda_chat_build_info Build information for this chat server.');
  lines.push('# TYPE cda_chat_build_info gauge');
  lines.push(`cda_chat_build_info{version="${config.version}",pod="${nats.pod}"} 1`);

  return `${lines.join('\n')}\n`;
}

// Kept off the Service and nginx: only Prometheus scrapes this port.
const metricsServer = http.createServer((request, response) => {
  if (request.url !== '/metrics' && request.url !== '/metrics?') {
    response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    response.end('Not found\n');
    return;
  }

  response.writeHead(200, { 'Content-Type': 'text/plain; version=0.0.4; charset=utf-8' });
  response.end(renderMetrics());
});

metricsServer.on('error', (error) => {
  console.error(`[metrics] server error: ${error.message}`);
});

metricsServer.listen(config.metricsPort, config.host, () => {
  console.log(`[metrics] Prometheus metrics on http://${config.host}:${config.metricsPort}/metrics`);
});

// The API works both with and without the /api prefix. This keeps direct
// access (http://host:8080/api/health) and the nginx reverse proxy
// (which preserves the prefix) working with the same code.
app.use('/api', api);
app.use('/', api);

app.get('*', (request, response, next) => {
  if (request.path.startsWith('/api') || request.path.startsWith('/ws')) {
    next();
    return;
  }

  response.sendFile(path.join(config.publicDir, 'index.html'));
});

app.use((request, response) => {
  if (request.path.startsWith('/api') || request.path.startsWith('/ws')) {
    response.status(404).json({
      error: { code: 'not_found', message: 'Endpoint not found.' },
    });
    return;
  }

  response.status(404).send('Not found');
});

// eslint-disable-next-line no-unused-vars
app.use((error, request, response, next) => {
  const parseError = error.type === 'entity.parse.failed';
  const databaseError = isDatabaseError(error);
  const status = parseError
    ? 400
    : databaseError
      ? 503
      : Number.isInteger(error.status) ? error.status : 500;

  if (status >= 500 && !databaseError) {
    console.error('[http] unhandled error:', error);
  }

  const message = parseError
    ? 'Request body must be valid JSON.'
    : databaseError
      ? 'The database is unavailable right now. Please try again shortly.'
      : status >= 500
        ? 'Internal server error.'
        : error.message;

  response.status(status).json({
    error: {
      code: databaseError
        ? 'database_unavailable'
        : error.code && typeof error.code === 'string' ? error.code : 'internal_error',
      message,
    },
  });
});

server.listen(config.port, config.host, () => {
  console.log(`[http] CDA chat server ${config.version} listening on http://${config.host}:${config.port}`);
  startDatabase();
});

let shuttingDown = false;

async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;

  console.log(`[app] ${signal} received, shutting down`);

  const forceExit = setTimeout(() => {
    console.error('[app] shutdown timed out');
    process.exit(1);
  }, 10_000);
  forceExit.unref();

  try {
    await hub.close();
    await new Promise((resolve) => server.close(resolve));
    await new Promise((resolve) => metricsServer.close(resolve));
    await stopDatabase();
  } catch (error) {
    console.error('[app] shutdown error:', error);
  }

  clearTimeout(forceExit);
  process.exit(0);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
