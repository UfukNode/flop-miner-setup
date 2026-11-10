#!/usr/bin/env bash
# Speed patch for FLOP miner-worker v0.1.286, until FLOP publishes a worker with its own fix.
#
# Worker v0.1.286 runs a full calibration check on every /session/open and /session/turn. The check
# reads every miner's calibration jobs from the public RPC (about 5,700 records on 10 Nov 2026) and
# took 11-19 seconds, so FLOP's gateway gave up on many sessions (flop-labs/network #168). FLOP fixed
# this in its worker v0.1.315 build, which is not in releases.json yet.
#
# The script copies the original worker file out of the official v0.1.286 image, checks its SHA-256,
# makes four small text changes and mounts the result read-only over the original file:
#   1. /session/open and /session/turn use the calibration status the worker refreshes every 30 s.
#   2. A failed TOPLOC evidence upload is written to the log instead of being dropped silently.
#   3. A retry does not register the same evidence on chain again (each registration costs a fee).
#   4. The evidence read-back is tried twice before the upload counts as failed (#172).
# Nothing else changes. Run it as root on the miner server:
#   bash patch-worker.sh            apply, or confirm it is applied
#   bash patch-worker.sh --undo     go back to the original worker file
set -euo pipefail

DIR=/opt/flop-miner
ENV_FILE=$DIR/miner.env
COMPOSE=$DIR/docker-compose.yml
P=$DIR/patches
TARGET=/repo/sdk/miner-worker/miner-worker.mjs
MOUNT="      - ./patches/miner-worker.mjs:$TARGET:ro"
WANT_IMAGE=ghcr.io/flop-labs/flop-core/miner-worker:v0.1.286@sha256:78211fe5f63820eeb1191e834f3a1eb7f573bc34348bdd4c0b0f07c7824fe7b5
WANT_ORIG=8a5cc221760fc7785c0e05b0fb1ceed447f3d355a4552dd51b45558d4199344b
C=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE")

recreate() {
  # Never restart the worker in the middle of a fence-guard run (step 18).
  if [ -e /run/flop-fence-guard.lock ]; then
    flock /run/flop-fence-guard.lock "${C[@]}" up -d --force-recreate worker < /dev/null
  else
    "${C[@]}" up -d --force-recreate worker < /dev/null
  fi
}

if [ "${1:-}" = "--undo" ]; then
  if grep -qxF -- "$MOUNT" "$COMPOSE"; then
    cp -p "$COMPOSE" "$COMPOSE.bak-$(date -u +%Y%m%d%H%M%S)"
    grep -vxF -- "$MOUNT" "$COMPOSE" > "$COMPOSE.tmp"
    cat "$COMPOSE.tmp" > "$COMPOSE" && rm -f "$COMPOSE.tmp"
    recreate
    echo "patch removed: the worker runs the original file again"
  else
    echo "the patch is not mounted; nothing to undo"
  fi
  exit 0
fi

IMG=$(grep '^FLOP_WORKER_IMAGE=' "$ENV_FILE" | cut -d= -f2-)
if [ "$IMG" != "$WANT_IMAGE" ]; then
  echo "this patch is only for worker v0.1.286; miner.env has: $IMG"
  exit 1
fi
command -v python3 > /dev/null || { echo "python3 is required"; exit 1; }

install -d -m 755 "$P"
docker run --rm --entrypoint cat "$IMG" "$TARGET" < /dev/null > "$P/miner-worker.v0.1.286.orig.mjs"
if [ "$(sha256sum < "$P/miner-worker.v0.1.286.orig.mjs" | cut -d' ' -f1)" != "$WANT_ORIG" ]; then
  echo "the original worker file is not the expected one; nothing was changed"
  exit 1
fi
echo "original worker file: verified"

python3 - "$P" <<'PY'
import sys
p = sys.argv[1]
t = open(p + "/miner-worker.v0.1.286.orig.mjs", encoding="utf-8").read()
changes = [
 ("calibration status from the 30-second check",
  "calibrationStatus:i.checkNow,calibrationSnapshot:i.snapshot",
  "calibrationStatus:i.snapshot,calibrationSnapshot:i.snapshot"),
 ("failed evidence uploads go to the log",
  "let H=this.publishToplocActivation(this.daSink,o).catch(()=>{}).finally(()=>{this.pendingToplocPublishes.delete(H)});",
  "let H=this.publishToplocActivation(this.daSink,o).catch(z=>{console.warn(`  [session] TOPLOC DA publish failed for turn ${o}: ${z?.message??z}`)}).finally(()=>{this.pendingToplocPublishes.delete(H)});"),
 ("no second evidence registration on a retry",
  "await this.options.register({channelId:r?.taskHash??o.channelId,turnIndex:r?.turnIndex??null,commitment:n,sizeBytes:e.length}),await this.options.checkRetention(n,e.length);",
  "(this.__flopRegistered??=new Set).has(G(n))||(await this.options.register({channelId:r?.taskHash??o.channelId,turnIndex:r?.turnIndex??null,commitment:n,sizeBytes:e.length}),this.__flopRegistered.add(G(n))),await this.options.checkRetention(n,e.length);"),
 ("evidence read-back tried twice",
  "let u=await this.fetch(n);if(!$e(u,e))throw new Error(\"session DA reconstructed bytes differ\");",
  "let u;for(let k=1;;k++){try{u=await this.fetch(n);break}catch(z){if(k>=2)throw z;console.warn(`  [session] TOPLOC DA read-back failed, retrying once: ${z?.message??z}`);await new Promise(q=>setTimeout(q,5e3))}}if(!$e(u,e))throw new Error(\"session DA reconstructed bytes differ\");"),
]
for name, old, new in changes:
    if t.count(old) != 1:
        sys.exit(f"cannot apply '{name}'; nothing was changed")
    t = t.replace(old, new)
    print("applied:", name)
open(p + "/miner-worker.new.mjs", "w", encoding="utf-8").write(t)
PY

docker run --rm --entrypoint node -v "$P/miner-worker.new.mjs:/x/miner-worker.mjs:ro" "$IMG" --check /x/miner-worker.mjs < /dev/null
echo "syntax check: ok"
NEW=$(sha256sum < "$P/miner-worker.new.mjs" | cut -d' ' -f1)
mv "$P/miner-worker.new.mjs" "$P/miner-worker.mjs"
chmod 644 "$P/miner-worker.mjs" "$P/miner-worker.v0.1.286.orig.mjs"

if ! grep -qxF -- "$MOUNT" "$COMPOSE"; then
  cp -p "$COMPOSE" "$COMPOSE.bak-$(date -u +%Y%m%d%H%M%S)"
  python3 - "$COMPOSE" "$MOUNT" <<'PY'
import sys
path, mount = sys.argv[1], sys.argv[2]
t = open(path, encoding="utf-8").read()
anchor = "      - worker-data:/data\n"
if t.count(anchor) != 1:
    sys.exit("docker-compose.yml is not the guide's file; add the mount by hand")
open(path, "w", encoding="utf-8").write(t.replace(anchor, anchor + mount + "\n"))
PY
  echo "docker-compose.yml: mount added"
fi
"${C[@]}" config --quiet

RUNNING=$("${C[@]}" exec -T worker sha256sum "$TARGET" < /dev/null 2> /dev/null | cut -d' ' -f1 || true)
if [ "$RUNNING" = "$NEW" ]; then
  echo "the worker already runs the patched file"
else
  recreate
  echo "worker recreated with the patched file"
fi
echo "patched file: $NEW"
