// The worker's own signer reconciliation (worker v0.1.336 and later). The fence file now holds the
// exact signed transaction and its short lifetime on the chain. The worker checks on chain whether
// that transaction was included or can no longer be included, then archives the fence itself and
// signs again without a restart. It never submits a transaction.
// Runs inside the worker container:
//   docker compose ... exec -T worker node --input-type=module < worker-reconcile.mjs
// Prints one JSON line: {"ok":true,...} when unlocked, or {"ok":false,"error":"..."} when the worker
// cannot prove it yet or does not support it (older workers and older fence files).
const base = `http://127.0.0.1:${process.env.SESSION_PORT || '8645'}`;
const token = process.env.SESSION_AUTH_TOKEN;
if (!token) throw new Error('SESSION_AUTH_TOKEN is required; do not disable authentication');
const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
const status = await fetch(`${base}/internal/signer-fence`, { headers, signal: AbortSignal.timeout(15000) });
if (!status.ok) throw new Error(`fence status HTTP ${status.status}`);
const state = await status.json();
if (!state.fenced || !state.fenceSha256) {
  console.log(JSON.stringify({ ok: false, error: 'not fenced' }));
} else {
  const res = await fetch(`${base}/internal/signer-fence`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ expectedFenceSha256: state.fenceSha256, mode: 'reconcile' }),
    signal: AbortSignal.timeout(180000),
  });
  let body;
  try { body = await res.json(); } catch { body = {}; }
  console.log(JSON.stringify(res.ok ? { ok: true, ...body } : { ok: false, http: res.status, error: String(body.error ?? '') }));
}
