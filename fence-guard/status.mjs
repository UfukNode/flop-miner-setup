// Reads the worker's own signer-fence status and its miner address. Read-only.
// Runs inside the worker container, so the session token never appears on the host command line:
//   docker compose ... exec -T worker node --input-type=module < status.mjs
const base = `http://127.0.0.1:${process.env.SESSION_PORT || '8645'}`;
const token = process.env.SESSION_AUTH_TOKEN;
if (!token) throw new Error('SESSION_AUTH_TOKEN is required; do not disable authentication');
const headers = { Authorization: `Bearer ${token}` };
const get = async (path) => {
  const res = await fetch(base + path, { headers, signal: AbortSignal.timeout(15000) });
  if (!res.ok) throw new Error(`${path} HTTP ${res.status}`);
  return res.json();
};
const fence = await get('/internal/signer-fence');
let minerAddress = null;
let ready = null;
try {
  const info = await get('/session/info');
  minerAddress = info.minerAddress ?? null;
  ready = info.is_ready ?? null;
} catch {}
console.log(JSON.stringify({ ...fence, minerAddress, ready }));
