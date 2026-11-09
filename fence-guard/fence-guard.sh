#!/usr/bin/env bash
# FLOP miner signer-fence guard, run by flop-fence-guard.timer every 2 minutes.
#
# When a transaction's outcome is unknown, the worker keeps a fence file and stops signing. This
# guard unlocks it only when that is provably safe:
#   1. If FLOP's own in-process recovery applies (a finalized failure), it runs that.
#   2. Otherwise it asks reconcile.mjs, a read-only chain check. Only on "release" (the stuck
#      transaction can no longer be included, the nonce is settled, nothing is pending and no
#      session or dispute is open) does it archive the fence file and restart the worker.
# Anything unexpected is logged and left for a person. DRY_RUN=1 stops before any change.
set -uo pipefail

G=/opt/flop-miner/fence-guard
ENV_FILE=/opt/flop-miner/miner.env
STATE_DIR=/data/.flop-miner-state
C=(docker compose --env-file "$ENV_FILE" -f /opt/flop-miner/docker-compose.yml)
DRY_RUN=${DRY_RUN:-0}
MAX_RELEASES=${MAX_RELEASES:-3}
umask 077

exec 9>/run/flop-fence-guard.lock
flock -n 9 || exit 0

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$G/guard.log"; }
status() { "${C[@]}" exec -T worker node --input-type=module < "$G/status.mjs" 2>/dev/null; }

[ -n "$("${C[@]}" ps --status running -q worker 2>/dev/null)" ] || exit 0

st=$(status) || { log "could not read the worker's fence status; trying again next run"; exit 0; }
[ "$(jq -r '.fenced' <<<"$st" 2>/dev/null)" = "true" ] || exit 0

sha=$(jq -r '.fenceSha256 // empty' <<<"$st")
recoverable=$(jq -r '.recoverableInProcess' <<<"$st")
miner=$(jq -r '.minerAddress // empty' <<<"$st")
log "worker is fenced (fence ${sha:0:12}, recoverableInProcess=$recoverable)"

if [ "$recoverable" = "true" ]; then
  if [ "$DRY_RUN" = 1 ]; then log "dry run: would run FLOP's in-process recovery"; exit 0; fi
  out=$("${C[@]}" exec -T worker node --input-type=module < "$G/recover.mjs" 2>&1)
  log "FLOP in-process recovery: $(tr '\n' ' ' <<<"$out" | cut -c1-400)"
  exit 0
fi

if [ -z "$sha" ] || [ -z "$miner" ]; then
  log "missing fence digest or miner address; leaving it"
  exit 0
fi

T=$(mktemp -d /run/flop-fence-guard.XXXXXX)
trap 'rm -rf "$T"' EXIT
names=$("${C[@]}" exec -T worker sh -c "cd $STATE_DIR 2>/dev/null && ls -1 -- *.signer-fence.json 2>/dev/null" < /dev/null || true)
for n in $names; do
  case "$n" in *[!A-Za-z0-9._-]*) log "unexpected fence file name; leaving it"; exit 0 ;; esac
  "${C[@]}" exec -T worker cat -- "$STATE_DIR/$n" < /dev/null > "$T/$n"
done

CLI=$(grep '^FLOP_CLI=' "$ENV_FILE" | cut -d= -f2-)
RPC=$(grep '^FLOP_RPC=' "$ENV_FILE" | cut -d= -f2-)
dec=$(docker run --rm --network host -v "$G:/guard:ro" -v "$T:/fence:ro" --entrypoint node "$CLI" \
  /guard/reconcile.mjs --miner "$miner" --fence-sha "$sha" --rpc "${RPC:-wss://rpc.devnet.flop.network}" 2>/dev/null | tail -n 1)
decision=$(jq -r '.decision // empty' <<<"$dec" 2>/dev/null)
reason=$(jq -r '.reason // empty' <<<"$dec" 2>/dev/null)

case "$decision" in
  release) ;;
  wait) log "wait: $reason$(jq -r 'if .etaMinutes then " (about \(.etaMinutes) min)" else "" end' <<<"$dec")"; exit 0 ;;
  block) log "BLOCKED, needs a person: $reason"; printf '%s\n' "$dec" > "$G/last-block.json"; exit 0 ;;
  none) log "no fence file found; leaving it"; exit 0 ;;
  *) log "the chain check gave no answer; trying again next run"; exit 0 ;;
esac

recent=$(find "$G/archive" -mindepth 1 -maxdepth 1 -type d -mmin -360 2>/dev/null | wc -l)
if [ "$recent" -ge "$MAX_RELEASES" ]; then
  log "BLOCKED, needs a person: $recent automatic unlocks in the last 6 hours"
  exit 0
fi

log "release: $reason"
if [ "$DRY_RUN" = 1 ]; then
  log "dry run: stopping before any change"
  exit 0
fi

file=$(jq -r '.fence.file' <<<"$dec")
A="$G/archive/$(date -u +%Y%m%dT%H%M%SZ)-${sha:0:12}"
install -d -m 700 "$A"
cp -- "$T/$file" "$A/fence.original.json"
[ "$(sha256sum < "$A/fence.original.json" | cut -d' ' -f1)" = "$sha" ] || { log "archive copy does not match the fence; stopping"; exit 1; }
printf '%s\n' "$dec" > "$A/proof.json"

"${C[@]}" exec -T worker sh -c '[ "$(sha256sum "$1" | cut -d" " -f1)" = "$2" ] && rm -f -- "$1"' _ "$STATE_DIR/$file" "$sha" < /dev/null \
  || { log "the fence changed before removal; stopping"; exit 1; }
"${C[@]}" restart worker < /dev/null > /dev/null 2>&1

for _ in $(seq 1 24); do
  sleep 5
  if st=$(status) && [ "$(jq -r '.fenced' <<<"$st")" = "false" ]; then
    log "unlocked: worker restarted without the fence (archive $A)"
    exit 0
  fi
done
log "the worker did not come back unlocked within 2 minutes; check: docker compose logs worker"
exit 1
