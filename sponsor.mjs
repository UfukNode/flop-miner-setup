// Ask the FLOP devnet stake sponsor to register this miner account.
// Runs inside the FLOP CLI image, which already holds the Polkadot libraries:
//   docker run --rm -v /opt/flop-miner:/work --entrypoint node "$FLOP_CLI" /work/sponsor.mjs
// It reads the one-line miner seed from /work/signer and never prints it.
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';

const require = createRequire('/app/');
const { Keyring } = require('@polkadot/keyring');
const { cryptoWaitReady } = require('@polkadot/util-crypto');
const stringToU8a = (text) => new Uint8Array(Buffer.from(text, 'utf8'));
const u8aToHex = (bytes) => `0x${Buffer.from(bytes).toString('hex')}`;

const SPONSOR = process.env.SPONSOR_URL || 'https://faucet.flop.network';
const seed = readFileSync(process.env.MINER_SEED_FILE || '/work/signer', 'utf8').trim();

await cryptoWaitReady();
const pair = new Keyring({ type: 'sr25519', ss58Format: 42 }).addFromUri(seed);
const chain = await (await fetch(`${SPONSOR}/chain`)).json();
const issuedAt = String(Date.now());
const message = `flop-sponsor/v1|miner|${chain.genesisHash}|${pair.address}|${issuedAt}`;
const signature = u8aToHex(pair.sign(stringToU8a(message)));

console.log(`Miner address: ${pair.address}`);
const res = await fetch(`${SPONSOR}/sponsor/miner`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ address: pair.address, issuedAt, signature }),
});
const body = await res.text();
console.log(`HTTP ${res.status}`);
console.log(body);
process.exit(res.ok ? 0 : 1);
