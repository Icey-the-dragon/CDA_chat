const STORAGE_KEY = 'cda-chat-username';
const HISTORY_LIMIT = 50;
const MAX_RENDERED = 300;

const AVATAR_OPTIONS = [
  '\u{1F600}', '\u{1F60E}', '\u{1F913}', '\u{1F973}', '\u{1F63A}', '\u{1F98A}',
  '\u{1F43C}', '\u{1F438}', '\u{1F984}', '\u{1F419}', '\u{1F41D}', '\u{1F989}',
  '\u{1F427}', '\u{1F996}', '\u{1F47E}', '\u{1F916}', '\u{1F47D}', '\u{1F383}',
  '\u{1F319}', '\u{2B50}', '\u{1F525}', '\u{1F308}', '\u{1F355}', '\u{2615}',
  '\u{1F3A7}', '\u{1F680}', '\u{1F3AE}', '\u{1F4DA}',
];

const COLOR_OPTIONS = [
  '#7c5cff', '#4f8cff', '#0ea5e9', '#17c8a0', '#2bb673', '#84cc16',
  '#f0b429', '#f97316', '#ff6b6b', '#e05fa8', '#d946ef', '#64748b',
];

const els = {
  username: document.querySelector('#username'),
  avatarButton: document.querySelector('#avatar-button'),
  avatarDialog: document.querySelector('#avatar-dialog'),
  avatarGrid: document.querySelector('#avatar-grid'),
  colorGrid: document.querySelector('#color-grid'),
  avatarPreview: document.querySelector('#avatar-preview'),
  avatarPreviewName: document.querySelector('#avatar-preview-name'),
  avatarReset: document.querySelector('#avatar-reset'),
  avatarCancel: document.querySelector('#avatar-cancel'),
  avatarClose: document.querySelector('#avatar-close'),
  avatarSave: document.querySelector('#avatar-save'),
  rooms: document.querySelector('#rooms'),
  roomCount: document.querySelector('#room-count'),
  newRoomForm: document.querySelector('#new-room-form'),
  newRoom: document.querySelector('#new-room'),
  connection: document.querySelector('#connection'),
  connectionLabel: document.querySelector('#connection-label'),
  roomTitle: document.querySelector('#room-title'),
  roomSubtitle: document.querySelector('#room-subtitle'),
  presence: document.querySelector('#presence'),
  messages: document.querySelector('#messages'),
  typing: document.querySelector('#typing'),
  composer: document.querySelector('#composer'),
  body: document.querySelector('#body'),
  send: document.querySelector('#send'),
  error: document.querySelector('#error'),
};

const state = {
  username: '',
  avatar: '',
  avatarColor: '',
  room: 'general',
  rooms: [],
  messages: [],
  seen: new Set(),
  users: [],
  profiles: {},
  typing: new Map(),
  ws: null,
  connected: false,
  reconnectAttempts: 0,
  reconnectTimer: null,
  typingSentAt: 0,
  joinedKey: null,
  errorTimer: null,
  historyToken: 0,
  profileToken: 0,
  closing: false,
};

function normalizeRoom(value) {
  return String(value ?? '')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, '-')
    .replace(/^[-_]+|[-_]+$/g, '')
    .slice(0, 64);
}

function roomFromHash() {
  try {
    return normalizeRoom(decodeURIComponent(location.hash.slice(1))) || null;
  } catch {
    return null;
  }
}

function normalizeUsername(value) {
  return String(value ?? '').trim().replace(/\s+/g, ' ').slice(0, 32);
}

function loadUsername() {
  const stored = normalizeUsername(localStorage.getItem(STORAGE_KEY));

  if (stored) return stored;

  const guest = `guest-${Math.random().toString(36).slice(2, 6)}`;
  localStorage.setItem(STORAGE_KEY, guest);
  return guest;
}

function colorFor(name) {
  let hash = 0;

  for (const character of name) {
    hash = (hash * 31 + (character.codePointAt(0) ?? 0)) >>> 0;
  }

  return `hsl(${hash % 360} 62% 48%)`;
}

function initialsFor(name) {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  const letters = parts.length > 1
    ? `${Array.from(parts[0])[0] ?? ''}${Array.from(parts[1])[0] ?? ''}`
    : Array.from(name.trim()).slice(0, 2).join('');

  return letters.toUpperCase();
}

function profileFor(username) {
  const profile = state.profiles[username];

  return {
    avatar: profile?.avatar || '',
    color: profile?.color || '',
  };
}

function paintAvatar(element, { name, avatar = '', color = '' } = {}) {
  element.textContent = avatar || initialsFor(name);
  element.classList.toggle('emoji', Boolean(avatar));
  element.style.background = color || colorFor(name);
  element.title = name;

  return element;
}

function ownProfile() {
  return { avatar: state.avatar, color: state.avatarColor };
}

function updateIdentityAvatar() {
  paintAvatar(els.avatarButton, { name: state.username || 'You', ...ownProfile() });
}

function applyOwnProfileToMessages() {
  const key = state.username.toLowerCase();
  let changed = false;

  for (const message of state.messages) {
    if (message.username.toLowerCase() !== key) continue;
    if (message.avatar === state.avatar && message.avatarColor === state.avatarColor) continue;

    message.avatar = state.avatar;
    message.avatarColor = state.avatarColor;
    changed = true;
  }

  if (changed) renderMessages({ scroll: false });
}

function formatTime(value) {
  const date = new Date(value);

  if (Number.isNaN(date.getTime())) return '';

  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

async function api(path, options = {}) {
  const { headers, ...rest } = options;
  const response = await fetch(`/api${path}`, {
    ...rest,
    headers: {
      'Content-Type': 'application/json',
      ...(headers || {}),
    },
  });

  let data = null;
  try {
    data = await response.json();
  } catch {
    // Some endpoints may return an empty body.
  }

  if (!response.ok) {
    const error = new Error(data?.error?.message || `Request failed (${response.status})`);
    error.status = response.status;
    throw error;
  }

  return data;
}

function showError(message) {
  els.error.textContent = message;
  els.error.hidden = false;
  clearTimeout(state.errorTimer);
  state.errorTimer = setTimeout(() => {
    els.error.hidden = true;
  }, 6000);
}

function setConnection(status) {
  els.connection.dataset.state = status;
  els.connectionLabel.textContent = status === 'online'
    ? 'online'
    : status === 'connecting'
      ? 'connecting\u2026'
      : 'offline';
}

function updateRoomHeader() {
  const info = state.rooms.find((room) => room.name === state.room);
  const count = info?.messageCount ?? state.messages.length;

  els.roomTitle.textContent = `# ${state.room}`;
  els.roomSubtitle.textContent = `${count} message${count === 1 ? '' : 's'} \u00b7 live over WebSocket`;
  els.body.placeholder = `Message #${state.room}`;
  document.title = `#${state.room} \u00b7 CDA Chat`;
}

function renderRooms() {
  const rooms = [...state.rooms];

  if (!rooms.some((room) => room.name === state.room)) {
    rooms.unshift({ name: state.room, messageCount: 0, lastActivity: null });
  }

  const fragment = document.createDocumentFragment();

  for (const room of rooms) {
    const item = document.createElement('li');
    const button = document.createElement('button');
    const hash = document.createElement('span');
    const name = document.createElement('span');
    const count = document.createElement('span');

    button.type = 'button';
    button.className = `room${room.name === state.room ? ' active' : ''}`;
    button.setAttribute('aria-current', room.name === state.room ? 'page' : 'false');
    button.addEventListener('click', () => {
      if (room.name !== state.room) joinRoom(room.name);
    });

    hash.className = 'hash';
    hash.textContent = '#';

    name.className = 'name';
    name.textContent = room.name;

    count.className = 'count';
    count.textContent = room.messageCount ? String(room.messageCount) : '';

    button.append(hash, name, count);
    item.append(button);
    fragment.append(item);
  }

  els.rooms.replaceChildren(fragment);
  els.roomCount.textContent = String(rooms.length);
}

async function refreshRooms({ silent = false } = {}) {
  try {
    const data = await api('/rooms');
    state.rooms = data.rooms;
    renderRooms();
    updateRoomHeader();
  } catch (error) {
    if (!silent) showError(error.message);
    renderRooms();
  }
}

function renderPresence() {
  els.presence.replaceChildren();

  const visible = state.users.slice(0, 5);

  for (const username of visible) {
    const avatar = document.createElement('span');
    avatar.className = 'avatar';
    avatar.dataset.username = username;
    paintAvatar(avatar, { name: username, ...profileFor(username) });
    els.presence.append(avatar);
  }

  if (state.users.length > visible.length) {
    const more = document.createElement('span');
    more.className = 'presence-more';
    more.textContent = `+${state.users.length - visible.length}`;
    els.presence.append(more);
  }
}

function renderMessage(message) {
  const item = document.createElement('li');
  const avatar = document.createElement('span');
  const bubble = document.createElement('div');
  const meta = document.createElement('div');
  const author = document.createElement('span');
  const time = document.createElement('time');
  const text = document.createElement('p');
  const mine = message.username.toLowerCase() === state.username.toLowerCase();

  item.className = `message${mine ? ' mine' : ''}`;

  avatar.className = 'avatar';
  paintAvatar(avatar, {
    name: message.username,
    avatar: message.avatar || '',
    color: message.avatarColor || '',
  });

  bubble.className = 'bubble';

  meta.className = 'meta';
  author.className = 'author';
  author.textContent = mine ? `${message.username} (you)` : message.username;
  time.className = 'time';
  time.dateTime = message.createdAt;
  time.textContent = formatTime(message.createdAt);

  meta.append(author, time);
  text.className = 'text';
  text.textContent = message.body;
  bubble.append(meta, text);
  item.append(avatar, bubble);

  return item;
}

function renderMessages({ scroll = true } = {}) {
  const nearBottom = els.messages.scrollHeight - els.messages.scrollTop - els.messages.clientHeight < 140;
  els.messages.replaceChildren();

  if (!state.messages.length) {
    const empty = document.createElement('li');
    const title = document.createElement('strong');
    const hint = document.createElement('span');

    empty.className = 'empty';
    title.textContent = `Welcome to #${state.room}`;
    hint.textContent = 'No messages yet. Say hi!';

    empty.append(title, hint);
    els.messages.append(empty);
  } else {
    const fragment = document.createDocumentFragment();

    for (const message of state.messages) {
      fragment.append(renderMessage(message));
    }

    els.messages.append(fragment);
  }

  if (scroll && nearBottom) {
    els.messages.scrollTop = els.messages.scrollHeight;
  }
}

function addMessage(message) {
  if (!message || message.room !== state.room) return false;

  const key = String(message.id);
  if (state.seen.has(key)) return false;

  state.seen.add(key);
  state.messages.push(message);

  while (state.messages.length > MAX_RENDERED) {
    const removed = state.messages.shift();
    state.seen.delete(String(removed.id));
  }

  return true;
}

function noteRoomActivity(message) {
  const existing = state.rooms.find((room) => room.name === message.room);

  if (existing) {
    existing.messageCount += 1;
    existing.lastActivity = message.createdAt;
  } else {
    state.rooms.push({
      name: message.room,
      messageCount: 1,
      lastActivity: message.createdAt,
    });
  }

  renderRooms();
  updateRoomHeader();
}

async function loadHistory({ scroll = true } = {}) {
  const token = ++state.historyToken;

  try {
    const data = await api(`/messages?room=${encodeURIComponent(state.room)}&limit=${HISTORY_LIMIT}`);

    if (token !== state.historyToken) return;

    let changed = false;
    for (const message of data.messages) {
      changed = addMessage(message) || changed;
    }

    if (changed) {
      renderMessages({ scroll });
      updateRoomHeader();
    }
  } catch (error) {
    if (token === state.historyToken) showError(error.message);
  }
}

async function loadProfile() {
  const username = state.username;

  if (!username) {
    state.avatar = '';
    state.avatarColor = '';
    updateIdentityAvatar();
    return;
  }

  const token = ++state.profileToken;

  try {
    const data = await api(`/profile?username=${encodeURIComponent(username)}`);

    if (token !== state.profileToken || username !== state.username) return;

    state.avatar = data.profile?.avatar || '';
    state.avatarColor = data.profile?.color || '';
  } catch (error) {
    if (token === state.profileToken) showError(error.message);
    return;
  }

  state.profiles[username] = ownProfile();
  state.joinedKey = null;

  updateIdentityAvatar();
  applyOwnProfileToMessages();
  renderPresence();

  if (state.connected) sendJoin();
}

let avatarDraft = { avatar: '', color: '' };

function ensureAvatarOptions() {
  if (els.avatarGrid.childElementCount === 0) {
    const fragment = document.createDocumentFragment();

    for (const option of AVATAR_OPTIONS) {
      const button = document.createElement('button');
      button.type = 'button';
      button.dataset.avatar = option;
      button.textContent = option;
      button.setAttribute('aria-label', `Use icon ${option}`);
      button.addEventListener('click', () => {
        avatarDraft.avatar = avatarDraft.avatar === option ? '' : option;
        renderAvatarDialog();
      });
      fragment.append(button);
    }

    els.avatarGrid.append(fragment);
  }

  if (els.colorGrid.childElementCount === 0) {
    const fragment = document.createDocumentFragment();

    for (const option of COLOR_OPTIONS) {
      const button = document.createElement('button');
      button.type = 'button';
      button.dataset.color = option;
      button.style.background = option;
      button.setAttribute('aria-label', `Use background ${option}`);
      button.addEventListener('click', () => {
        avatarDraft.color = avatarDraft.color === option ? '' : option;
        renderAvatarDialog();
      });
      fragment.append(button);
    }

    els.colorGrid.append(fragment);
  }
}

function renderAvatarDialog() {
  const name = state.username || 'You';

  paintAvatar(els.avatarPreview, { name, ...avatarDraft });
  els.avatarPreviewName.textContent = avatarDraft.avatar
    ? `${name} \u00b7 custom icon`
    : `${name} \u00b7 initials`;

  for (const button of els.avatarGrid.querySelectorAll('button')) {
    const selected = button.dataset.avatar === avatarDraft.avatar;
    button.classList.toggle('selected', selected);
    button.setAttribute('aria-pressed', String(selected));
  }

  for (const button of els.colorGrid.querySelectorAll('button')) {
    const selected = button.dataset.color === avatarDraft.color;
    button.classList.toggle('selected', selected);
    button.setAttribute('aria-pressed', String(selected));
  }
}

function openAvatarDialog() {
  ensureAvatarOptions();
  avatarDraft = ownProfile();
  renderAvatarDialog();
  els.avatarDialog.showModal();
}

function closeAvatarDialog() {
  if (els.avatarDialog.open) els.avatarDialog.close();
}

async function saveAvatar() {
  if (!state.username) {
    closeAvatarDialog();
    showError('Choose a nickname before saving an icon.');
    return;
  }

  const username = state.username;
  els.avatarSave.disabled = true;

  try {
    const data = await api('/profile', {
      method: 'PUT',
      body: JSON.stringify({ username, avatar: avatarDraft.avatar, color: avatarDraft.color }),
    });

    if (username !== state.username) return;

    state.avatar = data.profile?.avatar || '';
    state.avatarColor = data.profile?.color || '';
    state.profiles[username] = ownProfile();
    state.joinedKey = null;

    updateIdentityAvatar();
    applyOwnProfileToMessages();
    renderPresence();
    closeAvatarDialog();

    if (state.connected) sendJoin();
  } catch (error) {
    showError(error.message);
  } finally {
    els.avatarSave.disabled = false;
  }
}

function sendWs(payload) {
  if (state.ws?.readyState !== WebSocket.OPEN) return false;

  state.ws.send(JSON.stringify(payload));
  return true;
}

function sendJoin() {
  const key = `${state.room}\u0000${state.username}`;

  if (state.joinedKey === key) return true;
  if (!sendWs({
    type: 'join',
    room: state.room,
    username: state.username,
    avatar: state.avatar,
    color: state.avatarColor,
  })) return false;

  state.joinedKey = key;
  return true;
}

function markTyping(username) {
  if (!username || username.toLowerCase() === state.username.toLowerCase()) return;

  const previous = state.typing.get(username);
  if (previous) clearTimeout(previous);

  const timer = setTimeout(() => {
    state.typing.delete(username);
    renderTyping();
  }, 3200);

  state.typing.set(username, timer);
  renderTyping();
}

function renderTyping() {
  const names = [...state.typing.keys()];

  if (!names.length) {
    els.typing.textContent = '';
    return;
  }

  if (names.length === 1) {
    els.typing.textContent = `${names[0]} is typing\u2026`;
    return;
  }

  const visible = names.slice(0, 2).join(', ');
  const extra = names.length > 2 ? ` +${names.length - 2}` : '';
  els.typing.textContent = `${visible}${extra} are typing\u2026`;
}

function clearTyping() {
  for (const timer of state.typing.values()) clearTimeout(timer);
  state.typing.clear();
  renderTyping();
}

function handleSocketMessage(event) {
  let payload;

  try {
    payload = JSON.parse(event.data);
  } catch {
    return;
  }

  switch (payload.type) {
    case 'message': {
      const { message } = payload;

      if (message?.room !== state.room) break;
      if (addMessage(message)) {
        renderMessages();
        noteRoomActivity(message);
      }
      break;
    }

    case 'presence': {
      if (payload.room !== state.room) break;
      state.users = Array.isArray(payload.users) ? payload.users : [];
      state.profiles = payload.profiles && typeof payload.profiles === 'object'
        ? payload.profiles
        : {};
      renderPresence();
      break;
    }

    case 'profile': {
      const profile = payload.profile;

      if (!profile?.username) break;

      const key = profile.username.toLowerCase();
      const next = { avatar: profile.avatar || '', color: profile.color || '' };

      state.profiles[profile.username] = next;

      if (key === state.username.toLowerCase()) {
        state.avatar = next.avatar;
        state.avatarColor = next.color;
        updateIdentityAvatar();
      }

      let changed = false;
      for (const message of state.messages) {
        if (message.username.toLowerCase() !== key) continue;
        if (message.avatar === next.avatar && message.avatarColor === next.color) continue;

        message.avatar = next.avatar;
        message.avatarColor = next.color;
        changed = true;
      }

      renderPresence();
      if (changed) renderMessages({ scroll: false });
      break;
    }

    case 'typing': {
      if (payload.room !== state.room) break;
      markTyping(payload.username);
      break;
    }

    case 'joined': {
      state.joinedKey = `${payload.room}\u0000${payload.username}`;
      break;
    }

    case 'error': {
      showError(payload.message || 'The server rejected that action.');
      break;
    }

    default:
      break;
  }
}

function scheduleReconnect() {
  if (state.closing) return;

  const delay = Math.min(1000 * 2 ** state.reconnectAttempts, 15_000);
  state.reconnectAttempts += 1;

  clearTimeout(state.reconnectTimer);
  state.reconnectTimer = setTimeout(connect, delay);
}

function connect() {
  state.closing = false;
  clearTimeout(state.reconnectTimer);
  state.reconnectTimer = null;

  if (state.ws) {
    state.ws.onopen = null;
    state.ws.onmessage = null;
    state.ws.onclose = null;
    state.ws.onerror = null;
    state.ws.close();
  }

  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  let socket;

  try {
    socket = new WebSocket(`${protocol}//${location.host}/ws/`);
  } catch {
    setConnection('offline');
    scheduleReconnect();
    return;
  }

  state.ws = socket;
  setConnection('connecting');

  socket.onopen = () => {
    state.connected = true;
    state.reconnectAttempts = 0;
    setConnection('online');
    sendJoin();
    loadHistory();
    refreshRooms({ silent: true });
  };

  socket.onmessage = handleSocketMessage;

  socket.onerror = () => {
    if (socket.readyState !== WebSocket.CLOSED) socket.close();
  };

  socket.onclose = () => {
    const wasConnected = state.connected;
    state.connected = false;
    state.joinedKey = null;
    state.users = [];
    renderPresence();
    clearTyping();

    if (state.closing) {
      setConnection('offline');
      return;
    }

    setConnection(wasConnected ? 'connecting' : 'offline');
    scheduleReconnect();
  };
}

function joinRoom(room) {
  const normalized = normalizeRoom(room) || 'general';

  state.room = normalized;
  state.joinedKey = null;
  state.historyToken += 1;
  state.messages = [];
  state.seen.clear();
  state.users = [];
  clearTyping();

  history.replaceState(null, '', `#${normalized}`);

  renderRooms();
  renderMessages({ scroll: false });
  updateRoomHeader();
  renderPresence();

  if (state.connected) {
    sendJoin();
  }

  loadHistory();
  refreshRooms({ silent: true });
}

function autoGrow() {
  els.body.style.height = 'auto';
  els.body.style.height = `${Math.min(els.body.scrollHeight, 160)}px`;
}

async function submitMessage(event) {
  event.preventDefault();

  const body = els.body.value.trim();
  if (!body) return;

  if (!state.username) {
    els.username.focus();
    showError('Choose a nickname before sending a message.');
    return;
  }

  const payload = {
    room: state.room,
    username: state.username,
    body,
  };

  els.body.value = '';
  autoGrow();

  if (state.connected && sendJoin() && sendWs({ type: 'message', ...payload })) {
    // The server echoes the persisted message back to everyone in the room.
    return;
  }

  try {
    const data = await api('/messages', {
      method: 'POST',
      body: JSON.stringify(payload),
    });

    if (addMessage(data.message)) {
      renderMessages();
      noteRoomActivity(data.message);
    }
  } catch (error) {
    els.body.value = body;
    autoGrow();
    showError(error.message);
  }
}

function bindEvents() {
  els.composer.addEventListener('submit', submitMessage);

  els.avatarButton.addEventListener('click', openAvatarDialog);
  els.avatarSave.addEventListener('click', saveAvatar);
  els.avatarReset.addEventListener('click', () => {
    avatarDraft = { avatar: '', color: '' };
    renderAvatarDialog();
  });
  els.avatarCancel.addEventListener('click', closeAvatarDialog);
  els.avatarClose.addEventListener('click', closeAvatarDialog);
  els.avatarDialog.addEventListener('click', (event) => {
    if (event.target === els.avatarDialog) closeAvatarDialog();
  });

  els.body.addEventListener('input', () => {
    autoGrow();

    const now = Date.now();
    if (state.connected && state.username && now - state.typingSentAt > 1500) {
      state.typingSentAt = now;
      sendWs({ type: 'typing', room: state.room, username: state.username });
    }
  });

  els.body.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      els.composer.requestSubmit();
    }
  });

  let usernameTimer = null;

  els.username.addEventListener('input', () => {
    clearTimeout(usernameTimer);
    usernameTimer = setTimeout(() => {
      const username = normalizeUsername(els.username.value);
      if (!username) return;

      state.username = username;
      state.avatar = '';
      state.avatarColor = '';
      localStorage.setItem(STORAGE_KEY, username);
      state.joinedKey = null;

      updateIdentityAvatar();
      applyOwnProfileToMessages();
      loadProfile();
    }, 350);
  });

  els.username.addEventListener('blur', () => {
    els.username.value = state.username;
  });

  els.newRoomForm.addEventListener('submit', async (event) => {
    event.preventDefault();

    const name = normalizeRoom(els.newRoom.value);
    if (!name) {
      showError('Room names use letters, numbers, "-" and "_".');
      return;
    }

    try {
      await api('/rooms', {
        method: 'POST',
        body: JSON.stringify({ name }),
      });
      els.newRoom.value = '';
      await refreshRooms({ silent: true });
      joinRoom(name);
    } catch (error) {
      showError(error.message);
    }
  });

  window.addEventListener('hashchange', () => {
    const room = roomFromHash();
    if (room && room !== state.room) joinRoom(room);
  });

  window.addEventListener('beforeunload', () => {
    state.closing = true;
    clearTimeout(state.reconnectTimer);
    state.ws?.close(1000, 'page unloading');
  });
}

function init() {
  state.username = loadUsername();
  state.room = roomFromHash() || 'general';

  els.username.value = state.username;
  updateIdentityAvatar();

  renderRooms();
  renderMessages({ scroll: false });
  updateRoomHeader();
  bindEvents();
  connect();
  loadProfile();
  loadHistory();
  refreshRooms({ silent: true });
}

init();
