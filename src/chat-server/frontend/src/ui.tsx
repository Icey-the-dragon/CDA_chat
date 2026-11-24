import * as Dialog from '@radix-ui/react-dialog';
import { clsx, type ClassValue } from 'clsx';
import { twMerge } from 'tailwind-merge';
import type { ButtonHTMLAttributes, HTMLAttributes, InputHTMLAttributes, ReactNode } from 'react';

/** shadcn's cn(): merge conditional classes without Tailwind conflicts. */
export const cn = (...values: ClassValue[]) => twMerge(clsx(values));

const variants = {
  primary: 'bg-violet-600 text-white hover:bg-violet-500',
  soft: 'bg-zinc-800 text-zinc-100 hover:bg-zinc-700',
  ghost: 'text-zinc-400 hover:bg-zinc-800 hover:text-zinc-100',
};

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & { variant?: keyof typeof variants };

export function Button({ variant = 'soft', className, ...props }: ButtonProps) {
  return (
    <button
      className={cn(
        'inline-flex cursor-pointer items-center justify-center gap-2 rounded-lg px-3 py-2 text-sm font-medium transition disabled:cursor-not-allowed disabled:opacity-50',
        variants[variant],
        className,
      )}
      {...props}
    />
  );
}

export function Input({ className, ...props }: InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      className={cn(
        'w-full rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm outline-none placeholder:text-zinc-500 focus:border-violet-500',
        className,
      )}
      {...props}
    />
  );
}

export function Badge({ className, ...props }: HTMLAttributes<HTMLSpanElement>) {
  return <span className={cn('rounded-full bg-zinc-800 px-2 py-0.5 text-xs', className)} {...props} />;
}

function hashColor(name: string) {
  let hash = 0;
  for (const char of name) hash = (hash * 31 + (char.codePointAt(0) ?? 0)) >>> 0;
  return `hsl(${hash % 360} 62% 48%)`;
}

function initials(name: string) {
  return name.trim().split(/\s+/).slice(0, 2).map((part) => [...part][0] ?? '').join('').toUpperCase();
}

type AvatarProps = { name: string; emoji?: string; color?: string; className?: string };

export function Avatar({ name, emoji, color, className }: AvatarProps) {
  return (
    <span
      title={name}
      className={cn('grid size-9 shrink-0 place-items-center rounded-full text-xs font-semibold text-white', className)}
      style={{ background: color || hashColor(name) }}
    >
      {emoji || initials(name)}
    </span>
  );
}

type ModalProps = { title: string; children: ReactNode; open: boolean; onOpenChange: (open: boolean) => void };

export function Modal({ title, children, open, onOpenChange }: ModalProps) {
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-50 bg-black/70 backdrop-blur-sm" />
        <Dialog.Content className="fixed left-1/2 top-1/2 z-50 w-[min(92vw,26rem)] -translate-x-1/2 -translate-y-1/2 rounded-2xl border border-zinc-700 bg-zinc-900 p-5 shadow-2xl">
          <Dialog.Title className="text-lg font-semibold">{title}</Dialog.Title>
          <Dialog.Description className="sr-only">{title} settings</Dialog.Description>
          {children}
          <Dialog.Close asChild>
            <Button variant="ghost" className="absolute right-3 top-3 px-2" aria-label="Close">
              ✕
            </Button>
          </Dialog.Close>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
