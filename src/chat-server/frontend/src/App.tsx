import { useEffect, useRef, useState, type ChangeEvent, type FormEvent, type KeyboardEvent } from 'react';
import { Hash, Loader2, MessageSquare, Plus, Send, Users } from 'lucide-react';
import type { Profile } from './types';
import { Avatar, Badge, Button, Input, Modal, cn } from './ui';
import { useChat } from './useChat';

const EMOJIS = ['😀', '😎', '🤓', '🥳', '😺', '🦊', '🐼', '🐸', '🦄', '🐙', '🐝', '🦉', '🐧', '🦖', '🤖', '👽', '🌙', '⭐', '🔥', '🌈', '🍕', '☕', '🎧', '🚀', '🎮', '📚'];
const COLORS = ['#7c5cff', '#4f8cff', '#0ea5e9', '#17c8a0', '#2bb673', '#84cc16', '#f0b429', '#f97316', '#ff6b6b', '#e05fa8', '#d946ef', '#64748b'];

export default function App() {
  const chat = useChat();
  const [draft, setDraft] = useState('');
  const [nickname, setNickname] = useState(chat.username);
  const [newRoom, setNewRoom] = useState('');
  const [avatarOpen, setAvatarOpen] = useState(false);
  const [avatarDraft, setAvatarDraft] = useState({ avatar: '', color: '' });
  const list = useRef<HTMLOListElement>(null);
  const input = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    if (list.current) list.current.scrollTop = list.current.scrollHeight;
  }, [chat.messages.length, chat.room]);

  useEffect(() => {
    setAvatarDraft({ avatar: chat.ownProfile?.avatar ?? '', color: chat.ownProfile?.color ?? '' });
  }, [chat.ownProfile]);

  // Avoid a WebSocket re-join (and presence broadcast) on every keystroke.
  useEffect(() => {
    const timer = window.setTimeout(() => chat.setNickname(nickname), 350);
    return () => window.clearTimeout(timer);
  }, [nickname]);

  const submitMessage = (event: FormEvent) => {
    event.preventDefault();
    if (!draft.trim()) return;
    if (!chat.username) return chat.showError('Choose a nickname first.');
    chat.send(draft);
    setDraft('');
    if (input.current) input.current.style.height = 'auto';
  };

  const onComposerKey = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      event.currentTarget.form?.requestSubmit();
    }
  };

  const grow = (event: ChangeEvent<HTMLTextAreaElement>) => {
    event.target.style.height = 'auto';
    event.target.style.height = `${Math.min(event.target.scrollHeight, 160)}px`;
    chat.notifyTyping();
  };

  const submitRoom = (event: FormEvent) => {
    event.preventDefault();
    const name = newRoom.toLowerCase().trim().replace(/[^a-z0-9_-]+/g, '-').replace(/^[-_]+|[-_]+$/g, '');
    if (!name) return chat.showError('Room names use letters, numbers, "-" and "_".');
    chat.createRoom.mutate(name);
    setNewRoom('');
  };

  const saveAvatar = () => {
    if (!chat.username) return;
    chat.saveProfile.mutate({ username: chat.username, ...avatarDraft } as Profile, {
      onSuccess: () => setAvatarOpen(false),
    });
  };

  const statusStyle = {
    online: 'bg-emerald-400',
    connecting: 'bg-amber-400',
    offline: 'bg-rose-400',
  }[chat.status];

  return (
    <div className="flex h-dvh w-full overflow-hidden">
      <aside className="flex w-72 shrink-0 flex-col gap-5 border-r border-zinc-800 bg-zinc-900/60 p-4 max-md:w-56">
        <div className="flex items-center gap-3">
          <span className="grid size-10 place-items-center rounded-xl bg-violet-600 text-xl font-bold">#</span>
          <div>
            <h1 className="font-semibold leading-tight">CDA Chat</h1>
            <p className="text-xs text-zinc-500">MariaDB · REST · WebSockets</p>
          </div>
        </div>

        <label className="block text-xs text-zinc-400">
          Your nickname
          <Input
            value={nickname}
            maxLength={32}
            spellCheck={false}
            onChange={(event) => setNickname(event.target.value)}
            className="mt-1"
          />
        </label>

        <button className="flex items-center gap-3 text-left" onClick={() => setAvatarOpen(true)}>
          <Avatar name={chat.username} emoji={chat.ownProfile?.avatar} color={chat.ownProfile?.color} />
          <span className="text-xs text-zinc-500">Click your icon to change it</span>
        </button>

        <section className="flex min-h-0 flex-1 flex-col">
          <div className="mb-2 flex items-center justify-between">
            <h2 className="text-sm font-semibold">Rooms</h2>
            <Badge>{chat.rooms.length}</Badge>
          </div>
          <ol className="min-h-0 flex-1 space-y-1 overflow-y-auto">
            {chat.rooms.map((room) => (
              <li key={room.name}>
                <button
                  onClick={() => chat.selectRoom(room.name)}
                  className={cn(
                    'flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-left text-sm transition',
                    room.name === chat.room ? 'bg-violet-600/20 text-violet-200' : 'text-zinc-400 hover:bg-zinc-800',
                  )}
                >
                  <Hash className="size-4 shrink-0" />
                  <span className="flex-1 truncate">{room.name}</span>
                  <span className="text-xs tabular-nums text-zinc-500">{room.messageCount || ''}</span>
                </button>
              </li>
            ))}
          </ol>
          <form onSubmit={submitRoom} className="mt-2 flex gap-1">
            <Input
              value={newRoom}
              maxLength={64}
              placeholder="new-room"
              onChange={(event) => setNewRoom(event.target.value)}
            />
            <Button type="submit" aria-label="Create room" className="px-3">
              <Plus className="size-4" />
            </Button>
          </form>
        </section>

        <div className="flex items-center gap-2 text-xs text-zinc-400">
          <span className={cn('size-2 rounded-full', statusStyle)} />
          {chat.status}
        </div>
      </aside>

      <main className="flex min-w-0 flex-1 flex-col">
        <header className="flex items-center gap-4 border-b border-zinc-800 px-5 py-3">
          <div className="min-w-0 flex-1">
            <h2 className="truncate text-lg font-semibold"># {chat.room}</h2>
            <p className="text-xs text-zinc-500">
              {chat.messages.length} message{chat.messages.length === 1 ? '' : 's'} · live over WebSocket
            </p>
          </div>
          <div className="flex items-center gap-1" title={`${chat.users.length} online`}>
            <Users className="mr-1 size-4 text-zinc-500" />
            {chat.users.slice(0, 5).map((name) => (
              <Avatar key={name} name={name} emoji={chat.profiles[name]?.avatar} color={chat.profiles[name]?.color} className="size-7 -ml-2 border-2 border-zinc-950" />
            ))}
            {chat.users.length > 5 && <span className="text-xs text-zinc-500">+{chat.users.length - 5}</span>}
          </div>
        </header>

        <ol ref={list} className="min-h-0 flex-1 space-y-4 overflow-y-auto px-5 py-6">
          {chat.messages.length === 0 ? (
            <li className="flex h-full flex-col items-center justify-center gap-2 text-center text-zinc-500">
              <MessageSquare className="size-8" />
              <strong className="text-zinc-300">Welcome to #{chat.room}</strong>
              <span className="text-sm">No messages yet. Say hi!</span>
            </li>
          ) : (
            chat.messages.map((message) => {
              const mine = message.username.toLowerCase() === chat.username.toLowerCase();
              return (
                <li key={message.id} className={cn('flex gap-3', mine && 'flex-row-reverse')}>
                  <Avatar name={message.username} emoji={message.avatar} color={message.avatarColor} />
                  <div className={cn('max-w-[min(70%,40rem)]', mine && 'text-right')}>
                    <div className={cn('flex items-baseline gap-2 text-xs text-zinc-500', mine && 'flex-row-reverse')}>
                      <span>{mine ? `${message.username} (you)` : message.username}</span>
                      <time dateTime={message.createdAt}>
                        {new Date(message.createdAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                      </time>
                    </div>
                    <p className={cn('mt-1 inline-block whitespace-pre-wrap break-words rounded-2xl px-4 py-2 text-left text-sm', mine ? 'bg-violet-600 text-white' : 'bg-zinc-800')}>
                      {message.body}
                    </p>
                  </div>
                </li>
              );
            })
          )}
        </ol>

        <div className="h-5 px-5 text-xs text-zinc-500">
          {chat.typing.length === 1 && `${chat.typing[0]} is typing…`}
          {chat.typing.length > 1 && `${chat.typing.slice(0, 2).join(', ')} are typing…`}
        </div>

        <form onSubmit={submitMessage} className="flex items-end gap-2 border-t border-zinc-800 p-4">
          <textarea
            ref={input}
            rows={1}
            maxLength={2000}
            placeholder={`Message #${chat.room}`}
            value={draft}
            onChange={(event) => { setDraft(event.target.value); grow(event); }}
            onKeyDown={onComposerKey}
            className="max-h-40 flex-1 resize-none rounded-xl border border-zinc-700 bg-zinc-900 px-4 py-3 text-sm outline-none placeholder:text-zinc-500 focus:border-violet-500"
          />
          <Button variant="primary" type="submit" disabled={!draft.trim()} className="size-11 rounded-xl p-0" aria-label="Send">
            <Send className="size-4" />
          </Button>
        </form>
      </main>

      <Modal title="Your icon" open={avatarOpen} onOpenChange={setAvatarOpen}>
        <p className="mb-4 text-sm text-zinc-400">Pick an emoji and a background. Saved with your nickname.</p>
        <div className="grid grid-cols-8 gap-1">
          {EMOJIS.map((emoji) => (
            <button
              key={emoji}
              type="button"
              aria-label={`Use icon ${emoji}`}
              onClick={() => setAvatarDraft((d) => ({ ...d, avatar: d.avatar === emoji ? '' : emoji }))}
              className={cn('grid size-8 place-items-center rounded-lg text-lg', avatarDraft.avatar === emoji ? 'bg-violet-600' : 'hover:bg-zinc-800')}
            >
              {emoji}
            </button>
          ))}
        </div>
        <div className="my-4 grid grid-cols-6 gap-2">
          {COLORS.map((color) => (
            <button
              key={color}
              type="button"
              aria-label={`Use background ${color}`}
              onClick={() => setAvatarDraft((d) => ({ ...d, color: d.color === color ? '' : color }))}
              style={{ background: color }}
              className={cn('size-7 rounded-full', avatarDraft.color === color && 'ring-2 ring-white ring-offset-2 ring-offset-zinc-900')}
            />
          ))}
        </div>
        <div className="flex items-center justify-between">
          <Button variant="ghost" onClick={() => setAvatarDraft({ avatar: '', color: '' })}>Use initials</Button>
          <div className="flex gap-2">
            <Button onClick={() => setAvatarOpen(false)}>Cancel</Button>
            <Button variant="primary" onClick={saveAvatar} disabled={chat.saveProfile.isPending}>
              {chat.saveProfile.isPending ? <Loader2 className="size-4 animate-spin" /> : 'Save'}
            </Button>
          </div>
        </div>
      </Modal>

      {chat.error && (
        <div role="alert" className="fixed bottom-5 right-5 z-50 max-w-sm rounded-xl border border-rose-500/40 bg-rose-950 px-4 py-3 text-sm text-rose-100 shadow-xl">
          {chat.error}
        </div>
      )}
    </div>
  );
}
