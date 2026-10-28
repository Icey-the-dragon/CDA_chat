import { Router } from 'express';
import { config } from './config.js';
import { dbHealth, pingDatabase } from './db.js';
import * as store from './store.js';
import { HttpError, normalizeRoom, normalizeUsername, parseMessageInput, parseProfileInput } from './validation.js';

function wrap(handler) {
  return (request, response, next) => {
    Promise.resolve(handler(request, response, next)).catch(next);
  };
}

function parseLimit(value, fallback) {
  if (value === undefined) return fallback;

  const limit = Number.parseInt(value, 10);
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
    throw new HttpError(400, 'limit must be an integer between 1 and 100.');
  }

  return limit;
}

function parseBefore(value) {
  if (value === undefined || value === '') return null;

  if (!/^\d+$/.test(String(value))) {
    throw new HttpError(400, 'before must be a numeric message id.');
  }

  const id = Number(value);
  if (!Number.isSafeInteger(id) || id < 1) {
    throw new HttpError(400, 'before must be a positive message id.');
  }

  return id;
}

export function createApiRouter({ hub }) {
  const router = Router();

  router.get('/livez', (request, response) => {
    response.json({ status: 'ok', uptime: Math.round(process.uptime()) });
  });

  router.get('/health', wrap(async (request, response) => {
    const connected = await pingDatabase();
    const database = dbHealth();
    const healthy = connected && database.ready;

    response.status(healthy ? 200 : 503).json({
      status: healthy ? 'ok' : 'degraded',
      version: config.version,
      uptime: Math.round(process.uptime()),
      database: {
        ready: healthy,
        connected,
        schemaReady: database.ready,
        error: database.error,
      },
      realtime: hub.stats(),
    });
  }));

  router.get('/rooms', wrap(async (request, response) => {
    response.json({ rooms: await store.listRooms() });
  }));

  router.post('/rooms', wrap(async (request, response) => {
    const name = normalizeRoom(request.body?.name);
    response.status(201).json({ room: await store.createRoom(name) });
  }));

  router.get('/messages', wrap(async (request, response) => {
    const room = normalizeRoom(request.query.room, { fallback: 'general' });
    const limit = parseLimit(request.query.limit, config.limits.history);
    const before = parseBefore(request.query.before);
    const messages = await store.listMessages(room, { limit, before });

    response.json({
      room,
      messages,
      hasMore: messages.length === limit,
    });
  }));

  router.post('/messages', wrap(async (request, response) => {
    const message = await store.createMessage(parseMessageInput(request.body));
    hub.broadcastMessage(message);
    response.status(201).json({ message });
  }));

  router.get('/profile', wrap(async (request, response) => {
    const username = normalizeUsername(request.query.username);
    response.json({ profile: await store.getProfile(username) });
  }));

  router.put('/profile', wrap(async (request, response) => {
    const profile = await store.saveProfile(parseProfileInput(request.body));
    hub.broadcastProfile(profile);
    response.json({ profile });
  }));

  return router;
}
