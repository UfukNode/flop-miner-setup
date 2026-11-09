// FLOP miner signer-fence check. Read-only: it never signs or sends a transaction.
//
// The worker writes a fence file before every transaction and deletes it when the transaction is
// finalized. If the outcome is unknown (for example the RPC connection drops while it waits), the
// file stays and the worker stops signing until someone reconciles. This script decides whether the
// chain now proves the stuck transaction can no longer be included.
//
// Runs in the FLOP CLI image, which carries @polkadot/api:
//   docker run --rm --network host -v /opt/flop-miner/fence-guard:/guard:ro -v "$TMP:/fence:ro" \
//     --entrypoint node "$FLOP_CLI" /guard/reconcile.mjs --miner 5... --fence-sha <hex>
//
// Prints one JSON object. decision is one of:
//   release  the chain proves the stuck transaction can no longer be included, the account nonce is
//            settled, nothing from the account is pending and no session or dispute is open
//   wait     not yet; reason, blocksLeft and etaMinutes say why
//   block    something is unexpected; a person should look before anything is changed
//   none     no fence file
//
// Testing options: --at <block> judges as if that block were the finalized head, and
// --started-at <ms> replaces the time written in the fence file.

import { createRequire } from 'node:module';
import { readFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';

const require = createRequire('/app/');
const { ApiPromise, WsProvider } = require('@polkadot/api');
const { decodeAddress } = require('@polkadot/util-crypto');

const argv = process.argv.slice(2);
const opt = (name, def) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : def;
};
const MINER = opt('miner');
const RPC = opt('rpc', 'wss://rpc.devnet.flop.network');
const FENCE_DIR = opt('fence-dir', '/fence');
const FENCE_SHA = opt('fence-sha');
// The stuck transaction is signed right after the fence is written. Ten minutes covers the slowest
// signing the worker's library allows (its RPC requests time out after 60 seconds).
const SIGN_MARGIN_MS = Number(opt('sign-margin-s', '600')) * 1000;
const EXTRA_BLOCKS = Number(opt('extra-blocks', '64'));
const BUSY_CAP_MS = Number(opt('busy-cap-min', '90')) * 60_000;
const AT_BLOCK = opt('at');
const STARTED_AT = opt('started-at');

let api;
const iso = (ms) => new Date(ms).toISOString();
const finish = async (decision, reason, extra = {}) => {
  console.log(JSON.stringify({ decision, reason, checkedAt: iso(Date.now()), ...extra }));
  if (api) await api.disconnect().catch(() => {});
  process.exit(0);
};
setTimeout(() => {
  console.log(JSON.stringify({ decision: 'wait', reason: 'chain check timed out', checkedAt: iso(Date.now()) }));
  process.exit(0);
}, 150_000).unref();

// 1. The fence file, copied out of the worker by the guard.
let names;
try {
  names = readdirSync(FENCE_DIR).filter((n) => n.endsWith('.signer-fence.json'));
} catch (e) {
  await finish('block', `cannot read ${FENCE_DIR}: ${e.message}`);
}
if (names.length === 0) await finish('none', 'no fence file');
if (names.length > 1) await finish('block', 'more than one fence file', { files: names });
const bytes = readFileSync(`${FENCE_DIR}/${names[0]}`);
const sha = createHash('sha256').update(bytes).digest('hex');
if (FENCE_SHA && FENCE_SHA !== sha) await finish('block', 'the fence file differs from the one the worker reports', { sha256: sha });
let fence;
try {
  fence = JSON.parse(bytes.toString('utf8'));
} catch {
  await finish('block', 'the fence file is not JSON');
}
if (fence.version !== 2 || !Number.isSafeInteger(fence.startedAt)) await finish('block', `unsupported fence version ${fence.version}`);
const startedAt = STARTED_AT ? Number(STARTED_AT) : fence.startedAt;
const fenceInfo = { file: names[0], sha256: sha, attemptId: fence.attemptId, startedAt: iso(startedAt) };

if (!MINER) await finish('block', '--miner is required', { fence: fenceInfo });
const accountHex = `0x${Buffer.from(decodeAddress(MINER)).toString('hex')}`;
if (String(fence.signerAccountId).toLowerCase() !== accountHex) await finish('block', 'the fence names another account', { fence: fenceInfo });

// 2. The chain. Every read is one storage call at an exact block, so the public RPC is not flooded.
api = await ApiPromise.create({ provider: new WsProvider(RPC), noInitWarn: true, throwOnConnect: true });
if (api.genesisHash.toHex() !== String(fence.genesisHash).toLowerCase()) await finish('block', 'the fence belongs to another chain', { fence: fenceInfo });

const lookupType = (entry) => {
  const t = entry.creator.meta.type;
  return api.registry.createLookupType(t.isMap ? t.asMap.value : t.asPlain);
};
const T_TS = lookupType(api.query.timestamp.now);
const T_ACCOUNT = lookupType(api.query.system.account);
const T_BUSY = lookupType(api.query.minerStaking.minerBusyCount);
const KEY_TS = api.query.timestamp.now.key();
const KEY_ACCOUNT = api.query.system.account.key(MINER);
const KEY_BUSY = api.query.minerStaking.minerBusyCount.key(MINER);
const read = async (key, type, hash) => {
  const raw = await api.rpc.state.getStorage(key, hash);
  const value = raw && raw.isSome !== undefined ? (raw.isSome ? raw.unwrap() : null) : raw;
  return value ? api.registry.createType(type, value.toU8a(true)) : api.registry.createType(type);
};
const hashOf = (n) => api.rpc.chain.getBlockHash(n);
const tsAt = async (n) => Number((await read(KEY_TS, T_TS, await hashOf(n))).toString());
const nonceAt = async (hash) => (await read(KEY_ACCOUNT, T_ACCOUNT, hash)).nonce.toNumber();

let head;
let headHash;
if (AT_BLOCK) {
  head = Number(AT_BLOCK);
  headHash = await hashOf(head);
} else {
  headHash = await api.rpc.chain.getFinalizedHead();
  head = (await api.rpc.chain.getHeader(headHash)).number.toNumber();
}
const headTs = Number((await read(KEY_TS, T_TS, headHash)).toString());

// The worker's library (polkadot.js) gives every transaction a mortal era of
// min(blockHashCount, 5 minutes of blocks + 5), rounded up to a power of two (512 on FLOP devnet).
// After that many blocks past its signing block a transaction is invalid everywhere.
const c = api.consts;
const blockTimeMs = Number((c.babe?.expectedBlockTime || c.aura?.slotDuration || (c.timestamp?.minimumPeriod ? c.timestamp.minimumPeriod.muln(2) : 0) || 6000).toString());
const mortalLength = Math.min(c.system?.blockHashCount?.toNumber() || 250, Math.floor(300_000 / blockTimeMs) + 5);
const mortalPeriod = Math.min(Math.max(2 ** Math.ceil(Math.log2(mortalLength)), 4), 65_536);

// Last block whose timestamp is at or before t (the head when t is later than the head).
const blockAt = async (t) => {
  if (t >= headTs) return head;
  let hi = head;
  const step = Math.ceil(((headTs - t) / blockTimeMs) * 1.2) + 600;
  let lo = Math.max(1, head - step);
  while (lo > 1 && (await tsAt(lo)) > t) {
    hi = lo;
    lo = Math.max(1, lo - step);
  }
  while (hi - lo > 1) {
    const mid = Math.floor((lo + hi) / 2);
    if ((await tsAt(mid)) <= t) lo = mid;
    else hi = mid;
  }
  return lo;
};

if (headTs < startedAt) await finish('wait', 'the finalized chain is older than the fence time', { fence: fenceInfo });
const fenceBlock = await blockAt(startedAt);
const nonceAtFence = await nonceAt(await hashOf(fenceBlock));
const nonceNow = await nonceAt(headHash);
const chain = { finalized: head, finalizedAt: iso(headTs), blockTimeMs, mortalPeriod, fenceBlock, nonceAtFence, nonceNow };

if (nonceNow < nonceAtFence) await finish('block', 'the account nonce went backwards', { fence: fenceInfo, chain });
// While fenced the worker signs nothing, so at most the stuck transaction (plus one just before the
// fence time) can appear. More means another program is signing with the miner key.
if (nonceNow - nonceAtFence > 2) await finish('block', 'other transactions from the miner account were included after the fence', { fence: fenceInfo, chain });

const signDeadline = startedAt + SIGN_MARGIN_MS;
const minutesLeft = (blocks) => Math.ceil((blocks * blockTimeMs) / 60_000);
if (headTs < signDeadline) {
  const blocksLeft = Math.ceil((signDeadline - headTs) / blockTimeMs) + mortalPeriod + EXTRA_BLOCKS;
  await finish('wait', 'the stuck transaction could still be signed and sent', { fence: fenceInfo, chain, blocksLeft, etaMinutes: minutesLeft(blocksLeft) });
}
// The chain makes at most one block per slot, so the signing block is at most this far past the
// fence block. No search is needed.
const signDeadlineBlock = fenceBlock + Math.ceil(SIGN_MARGIN_MS / blockTimeMs) + 1;
const safeAfterBlock = signDeadlineBlock + mortalPeriod + EXTRA_BLOCKS;
Object.assign(chain, { signDeadlineBlock, safeAfterBlock });
if (head < safeAfterBlock) {
  const blocksLeft = safeAfterBlock - head;
  await finish('wait', 'the stuck transaction can still be included', { fence: fenceInfo, chain, blocksLeft, etaMinutes: minutesLeft(blocksLeft) });
}

if (!AT_BLOCK) {
  const nextIndex = (await api.rpc.system.accountNextIndex(MINER)).toNumber();
  const nonceAtBest = await nonceAt(await api.rpc.chain.getBlockHash());
  Object.assign(chain, { nextIndex, nonceAtBest });
  if (nextIndex !== nonceNow || nonceAtBest !== nonceNow) await finish('wait', 'a transaction from the miner account is pending', { fence: fenceInfo, chain });
}

// FLOP asks to let open sessions drain before the old worker process goes away. A fenced worker can
// no longer sign for them, so the wait is capped (on 9 Nov 2026 the count took 74 minutes to reach 0).
const busy = Number((await read(KEY_BUSY, T_BUSY, headHash)).toString());
chain.busy = busy;
const capAt = startedAt + BUSY_CAP_MS;
if (busy > 0 && headTs < capAt) {
  await finish('wait', `the miner still has ${busy} open sessions or disputes`, { fence: fenceInfo, chain, busy, etaMinutes: Math.ceil((capAt - headTs) / 60_000) });
}

// For the record: what the account got included after the fence time.
const landed = [];
for (let n = nonceAtFence; n < nonceNow; n++) {
  let lo = fenceBlock;
  let hi = head;
  while (hi - lo > 1) {
    const mid = Math.floor((lo + hi) / 2);
    if ((await nonceAt(await hashOf(mid))) > n) hi = mid;
    else lo = mid;
  }
  const entry = { block: hi, nonce: n };
  try {
    const blockHash = await hashOf(hi);
    const signed = await api.rpc.chain.getBlock(blockHash);
    const index = signed.block.extrinsics.findIndex((x) => x.isSigned && x.signer.toString() === MINER && x.nonce.toNumber() === n);
    if (index >= 0) {
      const x = signed.block.extrinsics[index];
      entry.call = `${x.method.section}.${x.method.method}`;
      entry.txHash = x.hash.toHex();
      const events = await (await api.at(blockHash)).query.system.events();
      const mine = events.filter((e) => e.phase.isApplyExtrinsic && e.phase.asApplyExtrinsic.toNumber() === index);
      entry.ok = mine.some((e) => e.event.section === 'system' && e.event.method === 'ExtrinsicSuccess');
    }
  } catch (e) {
    entry.note = `could not decode: ${e.message.slice(0, 120)}`;
  }
  landed.push(entry);
}

await finish(
  'release',
  (nonceNow === nonceAtFence
    ? 'the stuck transaction was never included and can no longer be'
    : 'the stuck transaction can no longer be included and the nonce is settled') +
    (busy > 0 ? `; ${busy} sessions or disputes still open after the wait limit` : ''),
  { fence: fenceInfo, chain, landed },
);
