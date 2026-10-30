#!/usr/bin/env bash
# Start the UAI workspace gateway and its public tunnel, then republish the
# address the Android loader reads.
#
#   ./start-gateway.sh              quick tunnel (no account needed)
#   ./start-gateway.sh --named      named tunnel (needs /root/.secrets/cf-tunnel.conf)
#   ./start-gateway.sh --status     show what is running and the live address
#   ./start-gateway.sh --stop       stop gateway, tunnel and supervisor
#
# Named tunnel config, /root/.secrets/cf-tunnel.conf, one KEY=VALUE per line:
#
#   TOKEN=<tunnel token from the Cloudflare dashboard>
#   HOSTNAME=uai.example.com
#
# A named tunnel keeps one permanent hostname. A quick tunnel gets a new random
# hostname on every restart, which is why endpoint.txt is rewritten and the
# loader reads it at run time instead of hardcoding a URL.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR=/root/var/run
LOG_DIR=/root/var/log
TOKEN_FILE=/root/.secrets/uai-gateway-token
PAT_FILE=/root/.secrets/github-pat
CF_CONF=/root/.secrets/cf-tunnel.conf
GATEWAY_LOG="$LOG_DIR/uai-gateway.log"
TUNNEL_LOG="$LOG_DIR/uai-tunnel.log"
SUP_LOG="$LOG_DIR/uai-tunnel-supervisor.log"
TUNNEL_PID="$RUN_DIR/uai-tunnel.pid"
SUP_PID="$RUN_DIR/uai-tunnel-supervisor.pid"
GATEWAY_PID="$RUN_DIR/uai-gateway.pid"
ENDPOINT_FILE="$ROOT/endpoint.txt"
PORT=8792
CLOUDFLARED=/root/.local/bin/cloudflared

mkdir -p "$RUN_DIR" "$LOG_DIR"

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

live_pid() {
	local file="$1"
	[ -f "$file" ] || return 1
	local pid
	pid="$(cat "$file" 2>/dev/null || true)"
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

cf_value() {
	[ -f "$CF_CONF" ] || return 0
	sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CF_CONF" | tail -1 | tr -d '\r'
}

stop_all() {
	for file in "$SUP_PID" "$TUNNEL_PID" "$GATEWAY_PID"; do
		if pid="$(live_pid "$file")"; then
			kill "$pid" 2>/dev/null || true
		fi
		rm -f "$file"
	done
	pkill -f "cloudflared tunnel --url http://127.0.0.1:$PORT" 2>/dev/null || true
	pkill -f "cloudflared tunnel run" 2>/dev/null || true
	# Full path so the pattern cannot match the shell running this script.
	pkill -f "python3 $ROOT/gateway.py" 2>/dev/null || true
	sleep 1
}

current_url() {
	if [ -f "$ENDPOINT_FILE" ]; then
		grep -oE 'https://[A-Za-z0-9.-]+' "$ENDPOINT_FILE" | head -1
	fi
}

if [ "${1:-}" = "--stop" ]; then
	stop_all
	echo "stopped"
	exit 0
fi

if [ "${1:-}" = "--status" ]; then
	echo "gateway:  $(live_pid "$GATEWAY_PID" || echo stopped)"
	echo "tunnel:   $(live_pid "$SUP_PID" || live_pid "$TUNNEL_PID" || echo stopped)"
	echo "address:  $(current_url || echo unknown)"
	port_open "$PORT" && echo "port:     8792 open" || echo "port:     8792 closed"
	curl -sS -m 5 http://127.0.0.1:$PORT/health 2>/dev/null || true
	echo
	exit 0
fi

MODE=quick
[ "${1:-}" = "--named" ] && MODE=named
[ -n "$(cf_value TOKEN)" ] && MODE=named

# 1. The VibeCode pool the gateway forwards to.
if ! port_open 8787; then
	echo "starting vibecode monitor..."
	(cd /root/vibecode-monitor && ./start.sh >/dev/null 2>&1) || true
	for _ in $(seq 1 40); do port_open 8787 && break; sleep 0.5; done
fi
port_open 8787 || { echo "vibecode monitor is not listening on 8787" >&2; exit 1; }

# 2. The gateway itself.
if ! port_open "$PORT"; then
	echo "starting gateway..."
	setsid nohup python3 "$ROOT/gateway.py" >"$GATEWAY_LOG" 2>&1 &
	echo $! >"$GATEWAY_PID"
	for _ in $(seq 1 20); do port_open "$PORT" && break; sleep 0.3; done
fi
port_open "$PORT" || { echo "gateway failed to start; see $GATEWAY_LOG" >&2; exit 1; }

# 3. The public tunnel.
# QUIC keeps dropping on this network, so pin HTTP/2 over IPv4 and keep a
# supervisor that restarts cloudflared if it exits. A dead tunnel used to answer
# with Cloudflare's HTML error page, which the client reported as a gateway error.
URL=""
NAMED_HOST=""
if [ "$MODE" = "named" ]; then
	NAMED_TOKEN="$(cf_value TOKEN)"
	NAMED_HOST="$(cf_value HOSTNAME)"
	if [ -z "$NAMED_TOKEN" ]; then
		echo "named mode needs TOKEN= in $CF_CONF" >&2
		exit 1
	fi
	if [ -z "$NAMED_HOST" ]; then
		echo "named mode needs HOSTNAME= in $CF_CONF" >&2
		exit 1
	fi
	URL="https://$NAMED_HOST"
	if pid="$(live_pid "$SUP_PID")"; then
		echo "named tunnel already supervised by $pid"
	else
		echo "starting named tunnel for $NAMED_HOST..."
		setsid nohup bash -c "while true; do $CLOUDFLARED tunnel --no-autoupdate \
--protocol http2 --edge-ip-version 4 run --token '$NAMED_TOKEN' >>'$TUNNEL_LOG' 2>&1; \
sleep 5; done" >"$SUP_LOG" 2>&1 &
		echo $! >"$SUP_PID"
	fi
else
	if pid="$(live_pid "$SUP_PID")"; then
		URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | tail -1 || true)"
	fi
	if [ -z "$URL" ]; then
		echo "starting quick tunnel..."
		: >"$TUNNEL_LOG"
		setsid nohup bash -c "while true; do $CLOUDFLARED tunnel --url \
http://127.0.0.1:$PORT --no-autoupdate --protocol http2 --edge-ip-version 4 \
>>'$TUNNEL_LOG' 2>&1; sleep 5; done" >"$SUP_LOG" 2>&1 &
		echo $! >"$SUP_PID"
		for _ in $(seq 1 80); do
			URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | tail -1 || true)"
			[ -n "$URL" ] && break
			sleep 0.5
		done
	fi
fi
[ -n "$URL" ] || { echo "tunnel did not report a URL; see $TUNNEL_LOG" >&2; exit 1; }

# 4. Verify the public route end to end before publishing anything. A fresh
# quick-tunnel name can lag in the local resolver, so ask Cloudflare over DoH and
# pin the answer with --resolve instead of trusting local DNS.
TOKEN="$(cat "$TOKEN_FILE")"
HOST="${URL#https://}"
resolve_ip() {
	curl -sS -m 8 -H 'accept: application/dns-json' \
		"https://cloudflare-dns.com/dns-query?name=$HOST&type=A" 2>/dev/null |
		python3 -c 'import json,sys; d=json.load(sys.stdin); a=[x["data"] for x in d.get("Answer",[]) if x.get("type")==1]; print(a[0] if a else "")' 2>/dev/null || true
}
code=""
for _ in $(seq 1 30); do
	IP="$(resolve_ip)"
	if [ -n "$IP" ]; then
		code="$(curl -sS -m 10 --resolve "$HOST:443:$IP" -o /dev/null -w '%{http_code}' \
			-H "Authorization: Bearer $TOKEN" "$URL/routes" || true)"
	else
		code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$URL/routes" || true)"
	fi
	[ "$code" = "200" ] && break
	sleep 1
done
[ "$code" = "200" ] || { echo "public gateway check returned $code" >&2; exit 1; }

# 5. Publish the live address. The loader reads endpoint.txt at run time, so this
# is the only thing that has to change when a quick tunnel rotates its name.
if [ "$(current_url || true)" != "$URL" ]; then
	printf '%s\n' "$URL" >"$ENDPOINT_FILE"
	echo "published $ENDPOINT_FILE"
fi

# gateway.lua is a generated, self-contained artifact. Runtime recovery only
# publishes the endpoint; it must not rewrite code or commit someone else's work.
if [ -f "$PAT_FILE" ] && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
	git -C "$ROOT" add -- endpoint.txt
	if ! git -C "$ROOT" diff --cached --quiet -- endpoint.txt; then
		PAT="$(cat "$PAT_FILE")"
		git -C "$ROOT" -c user.name="UAI gateway" -c user.email="uai@localhost" \
			commit --only -m "Publish the live gateway address" -- endpoint.txt >/dev/null
		git -C "$ROOT" -c http.extraheader="Authorization: Basic $(printf 'x-access-token:%s' "$PAT" | base64 -w0)" \
			push origin HEAD:main >/dev/null
		echo "pushed"
	fi
fi

echo "$URL"
echo "mode: $MODE"
echo "gateway token: $TOKEN_FILE"
echo "loader: $ROOT/examples/gateway.lua"
