import http from 'node:http';
import os from 'node:os';

// Minimal demo server. It exists only to make the four Kubernetes behaviours
// obvious and measurable: it reports which pod answered, can add latency, and
// can burn CPU to drive the HPA. It uses no third-party dependencies.
const PORT = Number(process.env.PORT || 8080);
const POD = process.env.POD_NAME || os.hostname();
const SLOW_MS = Number(process.env.SLOW_MS || 300);

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

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', 'http://localhost');
  res.setHeader('Content-Type', 'application/json');

  if (url.pathname === '/' || url.pathname === '/healthz') {
    res.end(JSON.stringify({ ok: true, pod: POD, slowMs: SLOW_MS }));
    return;
  }

  // Shows which replica served the request (balanceo).
  if (url.pathname === '/api/whoami') {
    res.end(JSON.stringify({ pod: POD }));
    return;
  }

  // CPU-bound work: one pod handles these sequentially, so the Service
  // spreading them across replicas finishes measurably sooner.
  if (url.pathname === '/api/slow') {
    await burnCpu(SLOW_MS);
    res.end(JSON.stringify({ pod: POD, burnedMs: SLOW_MS }));
    return;
  }

  // Same CPU work, longer, to push the HPA above its target.
  if (url.pathname === '/api/burn') {
    const ms = Math.min(Math.max(Number(url.searchParams.get('ms') || 1200), 1), 10000);
    await burnCpu(ms);
    res.end(JSON.stringify({ pod: POD, burnedMs: ms }));
    return;
  }

  res.statusCode = 404;
  res.end(JSON.stringify({ error: 'not found' }));
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`demo ${POD} listening on 0.0.0.0:${PORT}`);
});

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
    server.closeAllConnections();
  });
}
