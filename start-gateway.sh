#!/usr/bin/env bash
# Start the UAI workspace gateway and its public tunnel, then republish the
# loader with the current quick-tunnel URL.
#
# Quick tunnels get a new hostname every restart, which is why a hardcoded URL
# stops working. This script is the supported way to bring it back:
#
#   ./start-gateway.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR=/root/var/run
LOG_DIR=/root/var/log
TOKEN_FILE=/root/.secrets/uai-gateway-token
PAT_FILE=/root/.secrets/github-pat
GATEWAY_LOG="$LOG_DIR/uai-gateway.log"
TUNNEL_LOG="$LOG_DIR/uai-tunnel.log"
TUNNEL_PID="$RUN_DIR/uai-tunnel.pid"
GATEWAY_PID="$RUN_DIR/uai-gateway.pid"
PORT=8792

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

# 1. The VibeCode pool the gateway forwards to.
if ! port_open 8787; then
	echo "starting vibecode monitor..."
	(cd /root/vibecode-monitor && ./start.sh >/dev/null 2>&1) || true
	for _ in $(seq 1 30); do port_open 8787 && break; sleep 0.5; done
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

# 3. The public tunnel. Reuse a live one so the published URL stays stable.
tunnel_url() {
	grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1
}

running_tunnel_pid() {
	[ -f "$TUNNEL_PID" ] || return 1
	local pid
	pid="$(cat "$TUNNEL_PID" 2>/dev/null || true)"
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

URL=""
if pid="$(running_tunnel_pid)"; then
	URL="$(tunnel_url || true)"
fi

if [ -z "$URL" ]; then
	echo "starting tunnel..."
	: >"$TUNNEL_LOG"
	setsid nohup /root/.local/bin/cloudflared tunnel --url "http://127.0.0.1:$PORT" \
		--no-autoupdate >"$TUNNEL_LOG" 2>&1 &
	echo $! >"$TUNNEL_PID"
	for _ in $(seq 1 60); do
		URL="$(tunnel_url || true)"
		[ -n "$URL" ] && break
		sleep 0.5
	done
fi
[ -n "$URL" ] || { echo "tunnel did not report a URL; see $TUNNEL_LOG" >&2; exit 1; }

# 4. Verify the public route end to end before publishing anything. A fresh
# quick-tunnel name can take a while to reach the local resolver, so ask
# Cloudflare over DoH and pin the answer with --resolve instead of trusting it.
TOKEN="$(cat "$TOKEN_FILE")"
HOST="${URL#https://}"
resolve_ip() {
	curl -sS -m 8 -H 'accept: application/dns-json' \
		"https://cloudflare-dns.com/dns-query?name=$HOST&type=A" 2>/dev/null |
		python3 -c 'import json,sys; d=json.load(sys.stdin); a=[x["data"] for x in d.get("Answer",[]) if x.get("type")==1]; print(a[0] if a else "")' 2>/dev/null || true
}
code=""
for _ in $(seq 1 20); do
	IP="$(resolve_ip)"
	if [ -n "$IP" ]; then
		code="$(curl -sS -m 10 --resolve "$HOST:443:$IP" -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$URL/v1/models" || true)"
	else
		code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$URL/v1/models" || true)"
	fi
	[ "$code" = "200" ] && break
	sleep 1
done
[ "$code" = "200" ] || { echo "public gateway check returned $code" >&2; exit 1; }

# 5. Point the published loader at the live URL.
LOADER="$ROOT/examples/gateway.lua"
if ! grep -qF "$URL" "$LOADER"; then
	python3 - "$LOADER" "$URL" <<'PY'
import re, sys
path, url = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()
text = re.sub(r'local endpoint = "[^"]*"', 'local endpoint = "%s"' % url, text, count=1)
open(path, 'w', encoding='utf-8').write(text)
PY
	echo "updated $LOADER"
	if [ -f "$PAT_FILE" ] && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
		PAT="$(cat "$PAT_FILE")"
		git -C "$ROOT" add examples/gateway.lua gateway.py examples/GATEWAY_SETUP.md start-gateway.sh
		git -C "$ROOT" -c user.name="UAI gateway" -c user.email="uai@localhost" \
			commit -m "Point the Android gateway loader at the live tunnel" >/dev/null 2>&1 || true
		git -C "$ROOT" -c http.extraheader="Authorization: Basic $(printf 'x-access-token:%s' "$PAT" | base64 -w0)" \
			push origin HEAD:main
	fi
fi

echo "$URL"
echo "gateway token: $TOKEN_FILE"
echo "loader: $LOADER"
