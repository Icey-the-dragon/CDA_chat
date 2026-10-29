import { setTimeout as delay } from 'node:timers/promises';

const BASE_URL = (process.env.LOADGEN_URL || 'http://chat-server-service:8080').replace(/\/$/, '');
const WORKERS = Number.parseInt(process.env.LOADGEN_WORKERS || '10', 10);
const DELAY_MS = Number.parseInt(process.env.LOADGEN_DELAY_MS || '75', 10);
const DURATION_MS = Number.parseInt(process.env.LOADGEN_DURATION_MS || '180000', 10);
const ROOM = process.env.LOADGEN_ROOM || 'loadtest';
const PREFIX = (process.env.LOADGEN_PREFIX || `load-${process.pid}`).slice(0, 20);
const DEADLINE = Date.now() + DURATION_MS;

let sent = 0;
let failed = 0;

async function worker(index) {
  const username = `${PREFIX}-${index}`.slice(0, 32);
  let sequence = 0;

  while (Date.now() < DEADLINE) {
    const body = `${username} load message ${sequence++} ${new Date().toISOString()}`;

    try {
      const response = await fetch(`${BASE_URL}/api/messages`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ room: ROOM, username, body }),
      });

      await response.text();
      if (response.ok) sent += 1;
      else failed += 1;
    } catch {
      failed += 1;
    }

    await delay(DELAY_MS);
  }
}

console.log(
  `[loadgen] ${WORKERS} workers -> ${BASE_URL}/api/messages room=${ROOM} for ${Math.round(DURATION_MS / 1000)}s`,
);

await Promise.all(Array.from({ length: WORKERS }, (_, index) => worker(index)));

const seconds = Math.max(1, Math.round(DURATION_MS / 1000));
console.log(`[loadgen] done: ${sent} sent, ${failed} failed, ~${(sent / seconds).toFixed(1)} msg/s`);

if (failed > 0 && sent === 0) {
  process.exitCode = 1;
}
