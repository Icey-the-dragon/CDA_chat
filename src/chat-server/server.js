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
    await stopDatabase();
  } catch (error) {
    console.error('[app] shutdown error:', error);
  }

  clearTimeout(forceExit);
  process.exit(0);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
