#!/usr/bin/env bash
# Keeps the miner reachable through the cloudflared quick tunnel (run every minute by a systemd timer).
#  - If cloudflared got a new address (it restarts on its own), write it to miner.env and recreate the worker.
#  - If the worker answers locally but not through the tunnel 3 checks in a row, restart the tunnel,
#    then do the same.
# The worker is only recreated under the fence guard's lock, so the two never overlap.
set -uo pipefail
exec 9> /run/flop-tunnel-watch.lock
flock -n 9 || exit 0

DIR=/opt/flop-miner
ENV_FILE=$DIR/miner.env
FAILS=/run/flop-tunnel-watch.fails
C=(docker compose --env-file "$ENV_FILE" -f "$DIR/docker-compose.yml")
log() { echo "$(date -u +%FT%TZ) $*"; }

latest_url() {
  journalctl -u flop-tunnel -n 400 --no-pager -o cat 2> /dev/null \
    | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1 | sed 's#^https://##'
}

switch_to() {
  local new=$1 old
  old=$(grep '^SESSION_PUBLIC_HOST=' "$ENV_FILE" | cut -d= -f2)
  [ -n "$new" ] && [ "$new" != "$old" ] || return 1
  cp -p "$ENV_FILE" "$ENV_FILE.bak-tunnel"
  sed -i "s#^SESSION_PUBLIC_HOST=.*#SESSION_PUBLIC_HOST=$new#" "$ENV_FILE"
  flock /run/flop-fence-guard.lock "${C[@]}" up -d --force-recreate worker < /dev/null > /dev/null 2>&1
  log "tunnel address $old -> $new, worker recreated"
}

host=$(grep '^SESSION_PUBLIC_HOST=' "$ENV_FILE" | cut -d= -f2)
cur=$(latest_url)
if [ -n "$cur" ] && [ "$cur" != "$host" ]; then
  switch_to "$cur"
  echo 0 > "$FAILS"
  exit 0
fi

local_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:8645/session/info || true)
if [ "$local_code" != "401" ]; then
  # the worker itself is down or restarting; docker brings it back, the tunnel is not the problem
  exit 0
fi
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$host/session/info" || true)
if [ "$code" = "401" ]; then
  echo 0 > "$FAILS"
  exit 0
fi

n=$(( $(cat "$FAILS" 2> /dev/null || echo 0) + 1 ))
echo "$n" > "$FAILS"
log "outside check failed ($code), $n in a row"
[ "$n" -ge 3 ] || exit 0

log "restarting the tunnel"
systemctl restart flop-tunnel
for _ in $(seq 1 30); do
  sleep 3
  new=$(latest_url)
  if [ -n "$new" ] && [ "$new" != "$host" ]; then
    switch_to "$new"
    echo 0 > "$FAILS"
    exit 0
  fi
done
log "no new tunnel address after the restart; will try again"
