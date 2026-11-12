#!/usr/bin/env bash
# Speed patch for FLOP miner-worker v0.1.336 on FLOP's public devnet RPC.
#
# Worker v0.1.336 reads the miner's calibration and the readiness of its evidence store from the
# chain every time FLOP's gateway asks whether the miner is healthy (/session/info-proof, about
# once a minute) and on every session open and turn; for the readiness it also starts the
# da-validator program each time. On the public RPC one health check took 2.0-2.5 seconds in our
# test (12 Nov 2026), and the gateway cancelled 20 requests in 37 minutes, most of them health
# checks. The script copies the original worker file out of the official v0.1.336 image, checks
# its SHA-256, makes four small text changes and mounts the result read-only over the original:
#   1. Calibration comes from the status the worker refreshes in the background; the chain is
#      read only when that status is not ready (a stale status already counts as not ready).
#   2. A ready evidence-store check is reused for 20 seconds; a not-ready one is never reused.
#   3. A session's channel, once found on chain, is reused for 10 seconds (an open, its first
#      turn, the ack and the checkpoint come within about 2 seconds); a missing channel or an
#      error is never kept.
#   4. Refused session requests other than 401 are written to the log as "[http] ... -> CODE"
#      (anyone can make a 401, so those stay out of the log).
# Nothing else changes. Run it as root on the miner server:
#   bash patch-worker.sh            apply, or confirm it is applied
#   bash patch-worker.sh --undo     go back to the original worker file
# (Before 12 Nov 2026 this script was a different speed patch for worker v0.1.286; --undo removes
# either one.)
set -euo pipefail

DIR=/opt/flop-miner
ENV_FILE=$DIR/miner.env
COMPOSE=$DIR/docker-compose.yml
P=$DIR/patches
TARGET=/repo/sdk/miner-worker/miner-worker.mjs
MOUNT="      - ./patches/miner-worker.mjs:$TARGET:ro"
WANT_IMAGE=ghcr.io/flop-labs/flop-core/miner-worker:v0.1.336@sha256:b238975bb6ca282358e8f52f178152f26b4675ae6bbc5e1e305eacf92b27e39d
WANT_ORIG=33255f3fd456f6f1a3e0c1c22221654d54e0117a3108c2012f240cb9c644bc0d
ORIG=$P/miner-worker.v0.1.336.orig.mjs
C=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE")

recreate() {
  # Never restart the worker in the middle of a fence-guard or tunnel-watch run (steps 18 and 19).
  flock /run/flop-fence-guard.lock "${C[@]}" up -d --force-recreate worker < /dev/null
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
  echo "this patch is only for worker v0.1.336; miner.env has: $IMG"
  exit 1
fi
command -v python3 > /dev/null || { echo "python3 is required"; exit 1; }

install -d -m 755 "$P"
docker run --rm --entrypoint cat "$IMG" "$TARGET" < /dev/null > "$ORIG"
if [ "$(sha256sum < "$ORIG" | cut -d' ' -f1)" != "$WANT_ORIG" ]; then
  echo "the original worker file is not the expected one; nothing was changed"
  exit 1
fi
echo "original worker file: verified"

python3 - "$ORIG" "$P/miner-worker.new.mjs" <<'PY'
import sys
src, out = sys.argv[1], sys.argv[2]
t = open(src, encoding="utf-8").read()
changes = [
 # the calibration snapshot the worker refreshes in the background; a fresh chain check only when
 # the snapshot is not ready (stale snapshots already report not ready)
 ("calibration from the background snapshot",
  "calibrationStatus:o.checkReady,enclave:a,",
  "calibrationStatus:async()=>{let __flCal=o.snapshot();return __flCal&&__flCal.ready?__flCal:o.checkReady()},enclave:a,"),
 # a ready evidence-publication check is reused for 20 s; a not-ready answer is never reused
 ("publication readiness reused for 20 s",
  "...p?{publicationReady:()=>p.checkReady()}:{},",
  "...p?{publicationReady:(()=>{let __flOk=0;return async()=>{if(Date.now()-__flOk<2e4)return!0;let __r=await p.checkReady();return __r&&(__flOk=Date.now()),__r}})()}:{},"),
 # a found channel is reused for 10 s (an open, its first turn, ack and checkpoint come within
 # about 2 s); a missing channel or an error is never kept
 ("channel lookups reused for 10 s",
  "resolveChannel:x=>tie(e,x),",
  "resolveChannel:(()=>{let __flC=new Map;return x=>{let __flK=Buffer.from(x).toString(\"hex\"),__flH=__flC.get(__flK),__flN=Date.now();if(__flH&&__flN-__flH.t<1e4)return __flH.p;for(let[__k,__v]of __flC)__flN-__v.t>=1e4&&__flC.delete(__k);let __flP=tie(e,x).then(__v=>(__v||__flC.delete(__flK),__v),__x=>{throw __flC.delete(__flK),__x});return __flC.set(__flK,{t:__flN,p:__flP}),__flP}})(),"),
 # error answers other than 401 go to the log (anyone can make a 401, so those stay out)
 ("error answers other than 401 go to the log",
  'J=Lie(async(w,f)=>{let m=(y,C)=>{f.writeHead(y,{"Content-Type":"application/json"}),f.end(JSON.stringify(C,(k,U)=>typeof U=="bigint"?U.toString():U))},E;',
  'J=Lie(async(w,f)=>{let m=(y,C)=>{y>=400&&y!==401&&console.warn(`  [http] ${w.method} ${String(w.url||"").slice(0,32)} -> ${y} ${String(C?.error??"").slice(0,160)}`),f.writeHead(y,{"Content-Type":"application/json"}),f.end(JSON.stringify(C,(k,U)=>typeof U=="bigint"?U.toString():U))},E;'),
]
for name, old, new in changes:
    if t.count(old) != 1:
        sys.exit(f"cannot apply '{name}'; nothing was changed")
    t = t.replace(old, new)
    print("applied:", name)
open(out, "w", encoding="utf-8").write(t)
PY

docker run --rm --entrypoint node -v "$P/miner-worker.new.mjs:/x/miner-worker.mjs:ro" "$IMG" --check /x/miner-worker.mjs < /dev/null
echo "syntax check: ok"
NEW=$(sha256sum < "$P/miner-worker.new.mjs" | cut -d' ' -f1)
mv "$P/miner-worker.new.mjs" "$P/miner-worker.mjs"
chmod 644 "$P/miner-worker.mjs" "$ORIG"

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
