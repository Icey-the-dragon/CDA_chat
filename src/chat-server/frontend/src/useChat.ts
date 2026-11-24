import { useCallback, useEffect, useRef, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from './api';
import type { Message, Profile, SocketEvent } from './types';

const STORAGE_KEY = 'cda-chat-username';
const normalizeRoom = (value: string) =>
  value.toLowerCase().trim().replace(/[^a-z0-9_-]+/g, '-').replace(/^[-_]+|[-_]+$/g, '').slice(0, 64);

function roomFromHash() {
  try {
    return normalizeRoom(decodeURIComponent(location.hash.slice(1))) || null;
  } catch {
    return null;
  }
}

function loadUsername() {
  const saved = (localStorage.getItem(STORAGE_KEY) || '').trim().slice(0, 32);
  if (saved) return saved;
  const guest = `guest-${Math.random().toString(36).slice(2, 6)}`;
  localStorage.setItem(STORAGE_KEY, guest);
  return guest;
}

export function useChat() {
  const qc = useQueryClient();
  const [username, setUsernameState] = useState(loadUsername);
  const [room, setRoom] = useState(() => roomFromHash() || 'general');
  const [status, setStatus] = useState<'connecting' | 'online' | 'offline'>('connecting');
  const [users, setUsers] = useState<string[]>([]);
  const [profiles, setProfiles] = useState<Record<string, Pick<Profile, 'avatar' | 'color'>>>({});
  const [typing, setTyping] = useState<string[]>([]);
  const [error, setError] = useState('');

  const socket = useRef<WebSocket | null>(null);
  const live = useRef({ username, room });
  const ownAvatar = useRef<Pick<Profile, 'avatar' | 'color'>>({ avatar: '', color: '' });
  const typingTimers = useRef(new Map<string, number>());
  const lastTyping = useRef(0);
  live.current = { username, room };

  const rooms = useQuery({ queryKey: ['rooms'], queryFn: api.rooms });
  const messages = useQuery({ queryKey: ['messages', room], queryFn: () => api.messages(room) });
  const profile = useQuery({
    queryKey: ['profile', username],
    queryFn: () => api.profile(username),
    enabled: Boolean(username),
  });
  ownAvatar.current = {
    avatar: profile.data?.profile?.avatar ?? '',
    color: profile.data?.profile?.color ?? '',
  };

  const showError = useCallback((message: string) => setError(message), []);
  const join = useCallback((ws: WebSocket | null) => {
    if (ws?.readyState !== WebSocket.OPEN || !live.current.username) return;
    ws.send(JSON.stringify({ type: 'join', ...live.current, ...ownAvatar.current }));
  }, []);

  // One WebSocket for the whole session, with exponential reconnect. Live refs
  // keep the handlers current without tearing the socket down on every change.
  useEffect(() => {
    let disposed = false;
    let attempts = 0;
    let reconnect: number | undefined;

    const connect = () => {
      if (disposed) return;
      const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
      const ws = new WebSocket(`${scheme}//${location.host}/ws/`);
      socket.current = ws;
      setStatus('connecting');

      ws.onopen = () => {
        attempts = 0;
        setStatus('online');
        join(ws);
        qc.invalidateQueries({ queryKey: ['messages'] });
        qc.invalidateQueries({ queryKey: ['rooms'] });
      };

      ws.onmessage = (event) => {
        let data: SocketEvent;
        try {
          data = JSON.parse(event.data as string) as SocketEvent;
        } catch {
          return;
        }

        switch (data.type) {
          case 'message': {
            if (data.message.room !== live.current.room) break;
            qc.setQueryData<{ messages: Message[]; hasMore: boolean }>(['messages', data.message.room], (old) => {
              const list = old?.messages ?? [];
              if (list.some((m) => m.id === data.message.id)) return old ?? { messages: [], hasMore: false };
              return { messages: [...list, data.message].slice(-300), hasMore: old?.hasMore ?? false };
            });
            qc.invalidateQueries({ queryKey: ['rooms'] });
            break;
          }
          case 'presence':
            if (data.room === live.current.room) {
              setUsers(data.users);
              setProfiles(data.profiles);
            }
            break;
          case 'profile':
            setProfiles((old) => ({ ...old, [data.profile.username]: data.profile }));
            if (data.profile.username === live.current.username) qc.invalidateQueries({ queryKey: ['profile'] });
            break;
          case 'typing': {
            if (data.room !== live.current.room || data.username === live.current.username) break;
            const timers = typingTimers.current;
            window.clearTimeout(timers.get(data.username));
            timers.set(data.username, window.setTimeout(() => {
              timers.delete(data.username);
              setTyping([...timers.keys()]);
            }, 3000));
            setTyping([...timers.keys()]);
            break;
          }
          case 'error':
            showError(data.message);
            break;
        }
      };

      ws.onclose = () => {
        if (disposed) return;
        setStatus('offline');
        setUsers([]);
        setTyping([]);
        attempts += 1;
        reconnect = window.setTimeout(connect, Math.min(1000 * 2 ** attempts, 15_000));
      };
    };

    connect();
    return () => {
      disposed = true;
      window.clearTimeout(reconnect);
      socket.current?.close();
    };
  }, [qc, showError, join]);

  useEffect(() => {
    join(socket.current);
  }, [username, room, profile.data, join]);

  useEffect(() => {
    if (!error) return;
    const timer = window.setTimeout(() => setError(''), 6000);
    return () => window.clearTimeout(timer);
  }, [error]);

  const setNickname = (value: string) => {
    const name = value.trim().replace(/\s+/g, ' ').slice(0, 32);
    if (!name) return;
    localStorage.setItem(STORAGE_KEY, name);
    setUsernameState(name);
  };

  const selectRoom = (value: string) => {
    const next = normalizeRoom(value) || 'general';
    history.replaceState(null, '', `#${next}`);
    setRoom(next);
  };

  const createRoom = useMutation({
    mutationFn: (name: string) => api.createRoom(name),
    onSuccess: (_result, name) => {
      qc.invalidateQueries({ queryKey: ['rooms'] });
      selectRoom(name);
    },
    onError: (cause: Error) => showError(cause.message),
  });

  const saveProfile = useMutation({
    mutationFn: (value: Profile) => api.saveProfile(value),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['profile'] }),
    onError: (cause: Error) => showError(cause.message),
  });

  const send = (body: string) => {
    const text = body.trim();
    if (!text || !username) return;
    const ws = socket.current;
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'message', room, username, body: text }));
      return;
    }
    // REST fallback when the socket is down; the server still broadcasts it.
    api.sendMessage(room, username, text)
      .then(({ message }) => qc.setQueryData(['messages', room], (old: { messages: Message[]; hasMore: boolean } | undefined) => ({
        messages: [...(old?.messages ?? []), message],
        hasMore: old?.hasMore ?? false,
      })))
      .catch((cause: Error) => showError(cause.message));
  };

  const notifyTyping = () => {
    const ws = socket.current;
    if (ws?.readyState !== WebSocket.OPEN || !username) return;
    if (Date.now() - lastTyping.current < 1500) return;
    lastTyping.current = Date.now();
    ws.send(JSON.stringify({ type: 'typing', room, username }));
  };

  return {
    username, setNickname, room, selectRoom, status, users, profiles, typing,
    error, showError, rooms: rooms.data?.rooms ?? [], messages: messages.data?.messages ?? [],
    ownProfile: profile.data?.profile ?? null,
    createRoom, saveProfile, send, notifyTyping,
  };
}
