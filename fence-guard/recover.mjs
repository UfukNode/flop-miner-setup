// FLOP's own in-process recovery, from docs/miner-signer-fence-recovery.md in the worker image.
// It only works for a finalized failure that this same running worker observed; the worker
// re-verifies it on chain and archives the fence itself. It never submits a transaction.
// Runs inside the worker container:
//   docker compose ... exec -T worker node --input-type=module < recover.mjs
const base = `http://127.0.0.1:${process.env.SESSION_PORT || '8645'}`;
const token = process.env.SESSION_AUTH_TOKEN;
if (!token) throw new Error('SESSION_AUTH_TOKEN is required; do not disable authentication');
const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
const status = await fetch(`${base}/internal/signer-fence`, { headers, signal: AbortSignal.timeout(15000) });
if (!status.ok) throw new Error(`fence status HTTP ${status.status}`);
const state = await status.json();
console.log(JSON.stringify(state));
if (!state.fenced || !state.recoverableInProcess) throw new Error('this live worker cannot recover this fence');
const recovered = await fetch(`${base}/internal/signer-fence`, {
  method: 'POST',
  headers,
  body: JSON.stringify({ expectedFenceSha256: state.fenceSha256 }),
  signal: AbortSignal.timeout(30000),
});
console.log(await recovered.text());
if (!recovered.ok) throw new Error(`recovery refused: HTTP ${recovered.status}`);
