// Runs inside the cluster and hammers /api/burn on the demo Service so the
// HPA sees CPU above the 50% target and scales from 2 to 4 replicas.
const TARGET = process.env.TARGET || 'http://demo/api/burn?ms=1200';
const WORKERS = Number(process.env.WORKERS || 8);
const DURATION_MS = Number(process.env.DURATION_MS || 120000);

const deadline = Date.now() + DURATION_MS;
let ok = 0;
let failed = 0;

async function worker() {
  while (Date.now() < deadline) {
    try {
      const response = await fetch(TARGET);
      await response.arrayBuffer();
      if (response.ok) ok += 1;
      else failed += 1;
    } catch {
      failed += 1;
    }
  }
}

await Promise.all(Array.from({ length: WORKERS }, () => worker()));
console.log(JSON.stringify({ ok, failed }));
