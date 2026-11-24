import type { Message, Profile, Room } from './types';

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`/api${path}`, {
    ...init,
    headers: { 'Content-Type': 'application/json', ...init?.headers },
  });
  const data = await response.json().catch(() => null);
  if (!response.ok) throw new Error(data?.error?.message ?? `Request failed (${response.status})`);
  return data as T;
}

export const api = {
  rooms: () => request<{ rooms: Room[] }>('/rooms'),
  messages: (room: string) =>
    request<{ messages: Message[]; hasMore: boolean }>(`/messages?room=${encodeURIComponent(room)}`),
  profile: (username: string) =>
    request<{ profile: Profile | null }>(`/profile?username=${encodeURIComponent(username)}`),
  createRoom: (name: string) => request('/rooms', { method: 'POST', body: JSON.stringify({ name }) }),
  saveProfile: (profile: Profile) => request('/profile', { method: 'PUT', body: JSON.stringify(profile) }),
  sendMessage: (room: string, username: string, body: string) =>
    request<{ message: Message }>('/messages', {
      method: 'POST',
      body: JSON.stringify({ room, username, body }),
    }),
};
