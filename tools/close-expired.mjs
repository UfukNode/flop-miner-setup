// Closes this miner's expired compute channels with the permissionless computeChannel.timeout call,
// which refunds the buyer's escrow and closes the channel on chain.
//
// Why: worker v0.1.336 takes no new paid session while an evidence upload has failed. After an RPC
// outage the upload can keep failing, and the worker then stays `is_ready: false` for hours. The
// worker drops the failed upload once that session's channel is closed on chain, and a channel whose
// time (max_duration) is over can be closed by anyone with timeout.
//
// Runs in the FLOP CLI image, which carries @polkadot/api, with /opt/flop-miner mounted read-only:
//   docker run --rm --network host -v /opt/flop-miner:/work:ro --entrypoint node "$FLOP_CLI" \
//     /work/tools/close-expired.mjs [--send] [--rpc wss://...] 0xCHANNEL_ID ...
// Without --send it only checks each channel and prints the fee. It signs with the miner account in
// /work/signer and never prints the words. Stop the worker while you send, so the two never sign
// at the same time.
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';

const require = createRequire('/app/');
const { ApiPromise, WsProvider, Keyring } = require('@polkadot/api');
const { cryptoWaitReady } = require('@polkadot/util-crypto');

const argv = process.argv.slice(2);
const send = argv.includes('--send');
const rpcAt = argv.indexOf('--rpc');
const rpc = rpcAt >= 0 ? argv[rpcAt + 1] : 'wss://rpc.devnet.flop.network';
const ids = [...new Set(argv.filter((a, i) => /^0x[0-9a-fA-F]{64}$/.test(a) && argv[i - 1] !== '--rpc').map((a) => a.toLowerCase()))];
if (!ids.length) {
  console.log('no channel ids given');
  process.exit(0);
}
setTimeout(() => { console.log('timed out after 10 minutes'); process.exit(2); }, 600000).unref();

await cryptoWaitReady();
const words = readFileSync('/work/signer', 'utf8').trim();
const signer = new Keyring({ type: 'sr25519', ss58Format: 42 }).addFromUri(words);
const api = await ApiPromise.create({ provider: new WsProvider(rpc), noInitWarn: true });
const fmt = (x) => (Number(BigInt(x.toString()) / 1000000000000n) / 1e6).toFixed(4);
const finHash = await api.rpc.chain.getFinalizedHead();
const fin = (await api.rpc.chain.getHeader(finHash)).number.toNumber();
const at = await api.at(finHash);
console.log(`miner ${signer.address}, finalized block ${fin}`);

const due = [];
for (const id of ids) {
  const c = await at.query.computeChannel.channels(id);
  if (c.isNone) { console.log(`${id.slice(0, 14)}: not found`); continue; }
  const v = c.unwrap();
  const state = v.state.type ?? v.state.toString();
  const end = Number(v.openedAt.toString()) + Number(v.sla.maxDuration.toString());
  if (v.miner.toString() !== signer.address) { console.log(`${id.slice(0, 14)}: belongs to another miner`); continue; }
  if (state !== 'Open') { console.log(`${id.slice(0, 14)}: ${state}, nothing to do`); continue; }
  if (fin <= end) { console.log(`${id.slice(0, 14)}: open until block ${end}, ${end - fin} blocks left`); continue; }
  const fee = (await api.tx.computeChannel.timeout(id).paymentInfo(signer)).partialFee;
  console.log(`${id.slice(0, 14)}: open and expired at block ${end}, can be closed (fee about ${fmt(fee)} FLOP)`);
  due.push(id);
}

if (send && due.length) {
  let nonce = (await api.rpc.system.accountNextIndex(signer.address)).toNumber();
  for (const id of due) {
    await new Promise((resolve) => {
      let done = false;
      api.tx.computeChannel.timeout(id).signAndSend(signer, { nonce }, ({ status, events, dispatchError }) => {
        if (done) return;
        if (status.isInBlock) {
          done = true;
          if (dispatchError) {
            const m = dispatchError.isModule ? api.registry.findMetaError(dispatchError.asModule) : null;
            console.log(`${id.slice(0, 14)}: FAILED ${m ? `${m.section}.${m.name}` : dispatchError.toString()}`);
          } else {
            const names = events.map(({ event }) => `${event.section}.${event.method}`).filter((n) => n.startsWith('computeChannel'));
            console.log(`${id.slice(0, 14)}: closed (${names.join(', ')})`);
          }
          resolve();
        } else if (status.isDropped || status.isInvalid || status.isUsurped) {
          done = true;
          console.log(`${id.slice(0, 14)}: not included (${status.type})`);
          resolve();
        }
      }).catch((e) => { done = true; console.log(`${id.slice(0, 14)}: send failed: ${e.message}`); resolve(); });
    });
    nonce += 1;
  }
} else if (due.length) {
  console.log('check only: run again with --send to close them');
}
await api.disconnect();
process.exit(0);
