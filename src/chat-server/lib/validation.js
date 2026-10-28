import { config } from './config.js';

const ROOM_PATTERN = /^[a-z0-9][a-z0-9_-]*$/;
const USERNAME_PATTERN = /^[\p{L}\p{N}][\p{L}\p{N} ._-]*$/u;
const COLOR_PATTERN = /^#[0-9a-f]{6}$/i;

export class HttpError extends Error {
  constructor(status, message, code = 'bad_request') {
    super(message);
    this.name = 'HttpError';
    this.status = status;
    this.code = code;
  }
}

export function normalizeRoom(value, { fallback = null } = {}) {
  if (typeof value !== 'string' || value.trim() === '') {
    if (fallback) return fallback;
    throw new HttpError(400, 'Room name is required.');
  }

  const room = value.trim().toLowerCase();

  if (room.length > config.limits.room) {
    throw new HttpError(400, `Room name must be at most ${config.limits.room} characters.`);
  }
  if (!ROOM_PATTERN.test(room)) {
    throw new HttpError(400, 'Room names may only contain letters, numbers, "-" and "_".');
  }

  return room;
}

export function normalizeUsername(value) {
  if (typeof value !== 'string') {
    throw new HttpError(400, 'A username is required.');
  }

  const username = value.trim().replace(/\s+/g, ' ');

  if (!username) {
    throw new HttpError(400, 'A username is required.');
  }
  if (username.length > config.limits.username) {
    throw new HttpError(400, `Username must be at most ${config.limits.username} characters.`);
  }
  if (!USERNAME_PATTERN.test(username)) {
    throw new HttpError(400, 'Username contains unsupported characters.');
  }

  return username;
}

export function normalizeBody(value) {
  if (typeof value !== 'string') {
    throw new HttpError(400, 'Message body is required.');
  }

  const body = value.replace(/\r\n/g, '\n').trim();

  if (!body) {
    throw new HttpError(400, 'Message body cannot be empty.');
  }
  if (body.length > config.limits.message) {
    throw new HttpError(400, `Message must be at most ${config.limits.message} characters.`);
  }

  return body;
}

export function normalizeAvatar(value) {
  if (value === undefined || value === null || value === '') return '';

  if (typeof value !== 'string') {
    throw new HttpError(400, 'Avatar must be a short emoji or symbol.');
  }

  const avatar = value.trim();

  if (Array.from(avatar).length > 8 || /\s/u.test(avatar)) {
    throw new HttpError(400, 'Avatar must be at most 8 characters without spaces.');
  }

  return avatar;
}

export function normalizeAvatarColor(value) {
  if (value === undefined || value === null || value === '') return '';

  if (typeof value !== 'string' || !COLOR_PATTERN.test(value.trim())) {
    throw new HttpError(400, 'Avatar color must be a hex color such as #7c5cff.');
  }

  return value.trim().toLowerCase();
}

export function parseProfileInput(input = {}) {
  return {
    username: normalizeUsername(input.username),
    avatar: normalizeAvatar(input.avatar),
    color: normalizeAvatarColor(input.color),
  };
}

export function parseMessageInput(input = {}) {
  return {
    room: normalizeRoom(input.room, { fallback: 'general' }),
    username: normalizeUsername(input.username),
    body: normalizeBody(input.body),
  };
}
