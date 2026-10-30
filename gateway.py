"""Authenticated multi-provider inference gateway for the local model pools.

One bearer token fronts every upstream, so an Android Roblox client needs a
single URL and one secret. Only model listing and chat completions are exposed;
provider keys stay on this host.

Routes:

  /v1/models, /v1/chat/completions              local VibeCode pool (127.0.0.1:8787)
  /gonka/v1/models, /gonka/v1/chat/completions  GonkaRouter (GLM, DeepSeek, MiniMax)
  /zen/v1/models, /zen/v1/chat/completions      OpenCode Zen (only with a key on disk)

Diagnostics:

  GET /routes   prefixes that are live, so a loader only builds usable providers
  GET /health   upstream reachability plus the last few requests

Replies are non-streaming because Cloudflare Quick Tunnels do not carry SSE.
Every request is appended to a JSONL access log so a client-side failure can be
traced without guessing.
"""
import hmac
import http.client
import json
import os
import ssl
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import BoundedSemaphore, Lock

TOKEN_FILE = Path('/root/.secrets/uai-gateway-token')
GONKA_KEY_FILE = Path('/root/.secrets/gonkarouter-key')
ZEN_KEY_FILE = Path('/root/.secrets/zen-key')
LOG_DIR = Path('/root/var/log')
ACCESS_LOG = LOG_DIR / 'uai-gateway-access.jsonl'

SLOTS = BoundedSemaphore(4)
MAX_BODY = 2 * 1024 * 1024
MAX_REPLY = 16 * 1024 * 1024
UPSTREAM_TIMEOUT = 95
CLIENT_TIMEOUT = 180

# prefix, host, port, tls, key file, upstream path prefix, needs a key
ROUTES = (
    ('/v1/', '127.0.0.1', 8787, False, None, '/v1/', False),
    ('/gonka/v1/', 'api.gonkarouter.io', 443, True, GONKA_KEY_FILE, '/v1/', True),
    ('/zen/v1/', 'opencode.ai', 443, True, ZEN_KEY_FILE, '/v1/', True),
)

_recent = []
_recent_lock = Lock()


def has_key(path):
    try:
        return bool(path.read_text().strip())
    except OSError:
        return False


def active_routes():
    return [route for route in ROUTES if not route[6] or has_key(route[4])]


def route_for(path):
    for prefix, host, port, tls, key_file, upstream_prefix, _ in active_routes():
        if path.startswith(prefix):
            return prefix, host, port, tls, key_file, upstream_prefix + path[len(prefix):]
    return None


def allowed(method, path):
    route = route_for(path)
    if not route:
        return False
    rest = route[5]
    return (method == 'GET' and rest.endswith('/models')) or (
        method == 'POST' and rest.endswith('/chat/completions'))


def record(entry):
    entry['ts'] = round(time.time(), 3)
    line = json.dumps(entry, separators=(',', ':'))
    with _recent_lock:
        _recent.append(entry)
        del _recent[:-20]
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        with open(ACCESS_LOG, 'a', encoding='utf-8') as handle:
            handle.write(line + '\n')
    except OSError:
        pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def reply(self, status, body, extra=None):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        for name, value in (extra or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/routes':
            self.reply(200, json.dumps(
                {'routes': [route[0].rstrip('/') for route in active_routes()]}).encode())
            return
        if self.path == '/health':
            self.reply(200, json.dumps(self.health()).encode())
            return
        self.forward()

    def do_POST(self):
        self.forward()

    def health(self):
        pool = False
        try:
            probe = http.client.HTTPConnection('127.0.0.1', 8787, timeout=3)
            probe.request('GET', '/health')
            pool = probe.getresponse().status < 500
            probe.close()
        except (OSError, http.client.HTTPException):
            pool = False
        with _recent_lock:
            recent = list(_recent)[-5:]
        return {
            'ok': pool,
            'pool': pool,
            'gonka': has_key(GONKA_KEY_FILE),
            'zen': has_key(ZEN_KEY_FILE),
            'routes': [route[0].rstrip('/') for route in active_routes()],
            'recent': recent,
        }

    def forward(self):
        started = time.monotonic()
        entry = {'method': self.command, 'path': self.path}
        authorization = self.headers.get('Authorization', '')
        if not self.server.token or not hmac.compare_digest(
                authorization.encode(), ('Bearer ' + self.server.token).encode()):
            entry['status'] = 403
            record(entry)
            self.reply(403, b'{"error":"Access denied"}')
            return
        route = route_for(self.path)
        if not route or not allowed(self.command, self.path):
            entry['status'] = 404
            record(entry)
            self.reply(404, b'{"error":"Unknown route"}')
            return
        if not SLOTS.acquire(blocking=False):
            entry['status'] = 429
            record(entry)
            self.reply(429, b'{"error":"Gateway busy"}')
            return
        upstream = None
        try:
            self.connection.settimeout(CLIENT_TIMEOUT)
            length = int(self.headers.get('Content-Length', '0'))
            if self.headers.get('Transfer-Encoding') or not 0 <= length <= MAX_BODY:
                entry['status'] = 413
                record(entry)
                self.reply(413, b'{"error":"Invalid request size"}')
                return
            body = None
            if self.command == 'POST':
                payload = json.loads(self.rfile.read(length))
                if not isinstance(payload, dict):
                    raise ValueError('Expected object')
                entry['model'] = payload.get('model')
                payload['stream'] = False
                payload.pop('stream_options', None)
                body = json.dumps(payload).encode()

            _, host, port, tls, key_file, upstream_path = route
            headers = {'Content-Type': 'application/json'}
            if key_file:
                key = key_file.read_text().strip()
                if not key:
                    entry['status'] = 503
                    record(entry)
                    self.reply(503, b'{"error":"Upstream credential missing"}')
                    return
                headers['Authorization'] = 'Bearer ' + key

            if tls:
                upstream = http.client.HTTPSConnection(
                    host, port, timeout=UPSTREAM_TIMEOUT, context=ssl.create_default_context())
            else:
                upstream = http.client.HTTPConnection(host, port, timeout=UPSTREAM_TIMEOUT)
            upstream.request(self.command, upstream_path, body, headers)
            response = upstream.getresponse()
            data = response.read(MAX_REPLY + 1)
            entry['status'] = response.status
            if len(data) > MAX_REPLY:
                record(entry)
                self.reply(502, b'{"error":"Response too large"}')
            elif response.status >= 400:
                record(entry)
                self.reply(response.status, b'{"error":"Provider request failed","status":'
                           + str(response.status).encode() + b'}')
            else:
                record(entry)
                self.reply(response.status, data)
        except (ValueError, UnicodeError):
            entry['status'] = 400
            record(entry)
            self.reply(400, b'{"error":"Invalid JSON request"}')
        except (OSError, http.client.HTTPException) as exc:
            entry['status'] = 504
            entry['error'] = type(exc).__name__
            record(entry)
            self.reply(504, b'{"error":"Upstream connection failed or timed out; '
                            b'request was not replayed"}')
        finally:
            if upstream:
                upstream.close()
            SLOTS.release()
            entry['ms'] = round((time.monotonic() - started) * 1000)


if __name__ == '__main__':
    server = ThreadingHTTPServer(('127.0.0.1', 8792), Handler)
    server.daemon_threads = True
    server.token = TOKEN_FILE.read_text().strip()
    if len(server.token) < 32:
        raise SystemExit('Gateway token must have at least 32 characters')
    os.makedirs(LOG_DIR, exist_ok=True)
    server.serve_forever()
