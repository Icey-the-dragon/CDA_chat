const SVC = '__SVC__';
const N = Number(process.env.N || 20);
const PAR = Number(process.env.PAR || 10);

async function burst(url) {
  let next = 0;
  const t0 = Date.now();
  async function worker() {
    while (next < N) {
      const i = next++;
      try { await fetch(url + '?i=' + i); } catch { /* ignore */ }
    }
  }
  await Promise.all(Array.from({ length: PAR }, () => worker()));
  return Date.now() - t0;
}

const direct = await burst('http://127.0.0.1:8080/api/slow');
const balanced = await burst('http://' + SVC + '/api/slow');
console.log(`Sin balanceo (1 pod):   ${direct} ms`);
console.log(`Con balanceo (Service): ${balanced} ms`);
