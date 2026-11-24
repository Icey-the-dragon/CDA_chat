import http from 'node:http';
import os from 'node:os';
import { readFile } from 'node:fs/promises';

// Minimal demo server. It shows a live dashboard and exposes the endpoints
// used by the four Kubernetes exercises. It uses no third-party dependencies.
const PORT = Number(process.env.PORT || 8080);
const POD = process.env.POD_NAME || os.hostname();
const NODE = process.env.NODE_NAME || os.hostname();
const SLOW_MS = Number(process.env.SLOW_MS || 300);
const STARTED = new Date().toISOString();

let ownRequests = 0;

const PAGE = await readFile(new URL('./index.html', import.meta.url), 'utf8');

// Burn CPU in short slices, yielding to the event loop between them. A single
// long blocking loop would prevent the readiness probe from being answered,
// the pods would become NotReady, and the HPA would ignore their metrics.
async function burnCpu(ms) {
  const until = Date.now() + ms;
  let x = 0;
  while (Date.now() < until) {
    const sliceEnd = Math.min(Date.now() + 20, until);
    while (Date.now() < sliceEnd) {
      x = (x + Math.sqrt(x + 1)) % 1000003;
    }
    await new Promise((resolve) => setImmediate(resolve));
  }
  return x;
}

function json(res, value, status = 200) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(value));
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', 'http://localhost');

  if (url.pathname === '/' || url.pathname === '/index.html') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(PAGE);
    return;
  }

  if (url.pathname === '/healthz') {
    json(res, { ok: true, pod: POD, node: NODE });
    return;
  }

  // Every /api call is counted locally so the dashboard can show how many
  // requests this particular replica has served.
  if (url.pathname.startsWith('/api/')) ownRequests += 1;

  if (url.pathname === '/api/whoami') {
    json(res, { pod: POD, node: NODE, requests: ownRequests, time: new Date().toISOString() });
    return;
  }

  if (url.pathname === '/api/stats') {
    json(res, { pod: POD, node: NODE, requests: ownRequests, startedAt: STARTED });
    return;
  }

  // CPU-bound work: one pod handles these sequentially, so the Service
  // spreading them across replicas finishes measurably sooner.
  if (url.pathname === '/api/slow') {
    await burnCpu(SLOW_MS);
    json(res, { pod: POD, node: NODE, burnedMs: SLOW_MS });
    return;
  }

  // Same CPU work, longer, to push the HPA above its target.
  if (url.pathname === '/api/burn') {
    const ms = Math.min(Math.max(Number(url.searchParams.get('ms') || 1200), 1), 10000);
    await burnCpu(ms);
    json(res, { pod: POD, node: NODE, burnedMs: ms });
    return;
  }

  json(res, { error: 'not found' }, 404);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`demo ${POD} on ${NODE} listening on 0.0.0.0:${PORT}`);
});

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
    server.closeAllConnections();
  });
}
