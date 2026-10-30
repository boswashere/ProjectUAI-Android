#!/usr/bin/env bash
# Keep the public gateway reachable without human intervention.
#
# A Cloudflare quick tunnel gets a new hostname every time cloudflared restarts,
# and this host's network drops the tunnel's edge connection often enough that a
# restart happens on its own. The old hostname then answers with Cloudflare's
# 1033/502 HTML page, which the client reports as a gateway error.
#
# This loop closes that gap: it watches the live hostname, verifies it end to end,
# replaces a dead tunnel, and republishes endpoint.txt (which the loader reads at
# run time) whenever the address changes.
#
#   ./watch-gateway.sh          run in the foreground
#   ./watch-gateway.sh --stop   stop the watcher
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR=/root/var/run
LOG_DIR=/root/var/log
TOKEN_FILE=/root/.secrets/uai-gateway-token
PAT_FILE=/root/.secrets/github-pat
TUNNEL_LOG="$LOG_DIR/uai-tunnel.log"
WATCH_LOG="$LOG_DIR/uai-watch.log"
WATCH_PID="$RUN_DIR/uai-watch.pid"
ENDPOINT_FILE="$ROOT/endpoint.txt"
PORT=8792
INTERVAL=15
MIN_RESTART_GAP=60

mkdir -p "$RUN_DIR" "$LOG_DIR"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$WATCH_LOG"; }

if [ "${1:-}" = "--stop" ]; then
	if [ -f "$WATCH_PID" ]; then
		kill "$(cat "$WATCH_PID")" 2>/dev/null || true
		rm -f "$WATCH_PID"
	fi
	echo "watcher stopped"
	exit 0
fi

echo $$ >"$WATCH_PID"

port_open() {
	python3 - "$1" <<'PY'
import socket, sys
s = socket.socket()
s.settimeout(0.4)
try:
    s.connect(('127.0.0.1', int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

tunnel_url() {
	grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | tail -1
}

# 200 only when the gateway itself answers through the public hostname. A dead
# quick tunnel returns Cloudflare's HTML with 1033 or 502.
public_ok() {
	local url="$1" host ip code
	host="${url#https://}"
	ip="$(python3 -c "import socket;print(socket.gethostbyname('$host'))" 2>/dev/null || true)"
	if [ -n "$ip" ]; then
		code="$(curl -sS -m 12 --resolve "$host:443:$ip" -o /dev/null -w '%{http_code}' "$url/routes" 2>/dev/null || true)"
	else
		code="$(curl -sS -m 12 -o /dev/null -w '%{http_code}' "$url/routes" 2>/dev/null || true)"
	fi
	[ "$code" = "200" ]
}

publish() {
	local url="$1" current
	current="$(grep -oE 'https://[A-Za-z0-9.-]+' "$ENDPOINT_FILE" 2>/dev/null | head -1 || true)"
	[ "$current" = "$url" ] && return 0
	printf '%s\n' "$url" >"$ENDPOINT_FILE"
	log "published $url"
	if [ -f "$PAT_FILE" ] && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
		local pat
		pat="$(cat "$PAT_FILE")"
		git -C "$ROOT" add -- endpoint.txt >/dev/null 2>&1 || return 1
		if ! git -C "$ROOT" diff --cached --quiet -- endpoint.txt; then
			git -C "$ROOT" -c user.name="UAI gateway" -c user.email="uai@localhost" \
				commit --only -q -m "Publish the live gateway address" -- endpoint.txt >/dev/null 2>&1 || return 1
		fi
		git -C "$ROOT" -c http.extraheader="Authorization: Basic $(printf 'x-access-token:%s' "$pat" | base64 -w0)" \
			push -q origin HEAD:main >/dev/null 2>&1 && log "pushed $url"
	fi
}

restart_tunnel() {
	log "restarting tunnel"
	# Anchor the executable: the supervisor's bash -c argument also contains
	# this command, and an unanchored match kills the recovery loop itself.
	local pattern="^/root/.local/bin/cloudflared tunnel --url http://127[.]0[.]0[.]1:$PORT( |$)"
	local pids pid forced=false
	pids="$(pgrep -f "$pattern" || true)"
	for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
	sleep 6
	# cloudflared can hang after announcing graceful shutdown. Escalate only
	# the captured connectors, never a new child started by the supervisor.
	for pid in $pids; do
		if kill -0 "$pid" 2>/dev/null && pgrep -f "$pattern" | grep -qx "$pid"; then
			kill -KILL "$pid" 2>/dev/null || true
			forced=true
		fi
	done
	if [ "$forced" = true ]; then sleep 6; fi
	# The supervisor may already have exited. A live gateway port alone is not
	# evidence that anything is still serving the public hostname.
	"$ROOT/start-gateway.sh" >>"$WATCH_LOG" 2>&1 || true
}

last_restart=0
log "watcher started"

while true; do
	# The gateway and its pool must be up for any public check to mean anything.
	if ! port_open "$PORT"; then
		log "gateway down, restarting stack"
		"$ROOT/start-gateway.sh" >>"$WATCH_LOG" 2>&1 || true
	fi

	url="$(tunnel_url)"
	if [ -z "$url" ]; then
		log "no tunnel hostname in log yet"
		sleep "$INTERVAL"
		continue
	fi

	if public_ok "$url"; then
		publish "$url"
	else
		now="$(date +%s)"
		if [ $((now - last_restart)) -ge $MIN_RESTART_GAP ]; then
			last_restart="$now"
			log "public check failed for $url"
			restart_tunnel
			for _ in $(seq 1 40); do
				new="$(tunnel_url)"
				if [ -n "$new" ] && [ "$new" != "$url" ] && public_ok "$new"; then
					publish "$new"
					break
				fi
				sleep 1
			done
		else
			log "public check failed for $url (restart suppressed)"
		fi
	fi

	sleep "$INTERVAL"
done
