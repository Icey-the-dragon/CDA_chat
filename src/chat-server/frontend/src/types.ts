export type Profile = { username: string; avatar: string; color: string };
export type Room = { name: string; messageCount: number; lastActivity: string | null };
export type Message = {
  id: number;
  room: string;
  username: string;
  avatar: string;
  avatarColor: string;
  body: string;
  createdAt: string;
};

export type SocketEvent =
  | { type: 'message'; message: Message }
  | { type: 'presence'; room: string; users: string[]; profiles: Record<string, Pick<Profile, 'avatar' | 'color'>> }
  | { type: 'profile'; profile: Profile }
  | { type: 'typing'; room: string; username: string }
  | { type: 'error'; code: string; message: string };
