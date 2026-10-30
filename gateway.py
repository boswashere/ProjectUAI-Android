"""Authenticated multi-provider inference gateway for the local model pools.

One bearer token fronts every upstream, so an Android Roblox client needs a
single URL and one secret. Only model listing and chat completions are exposed;
provider keys stay on this host.

Routes:

  /v1/models, /v1/chat/completions              local VibeCode pool (127.0.0.1:8787)
  /gonka/v1/models, /gonka/v1/chat/completions  GonkaRouter (GLM, DeepSeek, MiniMax)
  /zen/v1/models, /zen/v1/chat/completions      OpenCode Zen (only with a key on disk)
  /fcc/v1, /rsiai/v1, /hinoki/v1               existing configured provider connections

Diagnostics:

  GET /routes   prefixes that are live, so a loader only builds usable providers
  GET /health   upstream reachability plus the last few requests

Replies intentionally use non-streaming JSON for this client integration.
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
from gateway_sources import ProviderKey, configured_models

TOKEN_FILE = Path('/root/.secrets/uai-gateway-token')
GONKA_KEY_FILE = Path('/root/.secrets/gonkarouter-key')
ZEN_KEY_FILE = Path('/root/.secrets/zen-key')
FCC_KEY = ProviderKey('fcc')
RSIAI_KEY = ProviderKey('rsiai')
HINOKI_KEY = ProviderKey('hinoki')
LOG_DIR = Path('/root/var/log')
ACCESS_LOG = LOG_DIR / 'uai-gateway-access.jsonl'

SLOTS = BoundedSemaphore(4)
MAX_BODY = 2 * 1024 * 1024
MAX_REPLY = 16 * 1024 * 1024
UPSTREAM_TIMEOUT = 80
# Total wall clock allowed per request. Cloudflare ends a request near 100s.
TOTAL_BUDGET = 88
CLIENT_TIMEOUT = 180

# prefix, host, port, tls, key file, upstream path prefix, needs a key
ROUTES = (
    ('/v1/', '127.0.0.1', 8787, False, None, '/v1/', False),
    ('/gonka/v1/', 'api.gonkarouter.io', 443, True, GONKA_KEY_FILE, '/v1/', True),
    ('/zen/v1/', 'opencode.ai', 443, True, ZEN_KEY_FILE, '/zen/v1/', True),
    ('/fcc/v1/', '127.0.0.1', 8082, False, FCC_KEY, '/v1/', True),
    ('/rsiai/v1/', 'www.rsiai.net', 443, True, RSIAI_KEY, '/v1/', True),
    ('/hinoki/v1/', 'inference.hinoki.security', 443, True, HINOKI_KEY, '/v1/', True),
)
ROUTE_PROVIDERS = {
    '/v1': 'vibecode', '/gonka/v1': 'gonka', '/zen/v1': 'opencode',
    '/fcc/v1': 'fcc', '/rsiai/v1': 'rsiai', '/hinoki/v1': 'hinoki',
}

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
    rest = path[len(route[0]):]
    completion = 'messages' if route[0] == '/fcc/v1/' else 'chat/completions'
    return (method, rest) in {('GET', 'models'), ('POST', completion)}


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
            routes = [route[0].rstrip('/') for route in active_routes()]
            self.reply(200, json.dumps({
                'routes': routes,
                'providers': {route: {'models': configured_models(ROUTE_PROVIDERS[route])}
                              for route in routes},
            }).encode())
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
            if route[0] == '/fcc/v1/':
                headers['anthropic-version'] = '2023-06-01'
            if key_file:
                key = key_file.read_text().strip()
                if not key:
                    entry['status'] = 503
                    record(entry)
                    self.reply(503, b'{"error":"Upstream credential missing"}')
                    return
                headers['Authorization'] = 'Bearer ' + key

            # The host network drops TLS mid-handshake often enough that a single
            # attempt turns into a user-visible failure, so a broken connection is
            # retried once. The whole exchange shares one budget: Cloudflare ends a
            # request at roughly 100 seconds and answers with its own HTML page, so
            # a second attempt only starts if there is real room for it.
            status = 0
            data = b''
            deadline = time.monotonic() + TOTAL_BUDGET
            for attempt in (1, 2):
                remaining = deadline - time.monotonic()
                if remaining < 5:
                    break
                if tls:
                    upstream = http.client.HTTPSConnection(
                        host, port, timeout=min(UPSTREAM_TIMEOUT, remaining),
                        context=ssl.create_default_context())
                else:
                    upstream = http.client.HTTPConnection(
                        host, port, timeout=min(UPSTREAM_TIMEOUT, remaining))
                try:
                    upstream.request(self.command, upstream_path, body, headers)
                    response = upstream.getresponse()
                    status = response.status
                    data = response.read(MAX_REPLY + 1)
                finally:
                    upstream.close()
                    upstream = None
                if status < 500 and data:
                    break
                if deadline - time.monotonic() < 15:
                    break
                entry['retried'] = True

            entry['status'] = status
            if len(data) > MAX_REPLY:
                entry['status'] = 502
                record(entry)
                self.reply(503, b'{"error":"Upstream response too large"}')
            elif status >= 500:
                # Cloudflare replaces an origin 502/504 with its own HTML page, and
                # the client then reports a parse error instead of the real cause.
                # Answer 503 with JSON so the message survives the tunnel.
                detail = b''
                try:
                    decoded = json.loads(data)
                    message = decoded.get('error') if isinstance(decoded, dict) else None
                    if isinstance(message, dict):
                        message = message.get('message')
                    if message:
                        detail = str(message).encode()[:400]
                except (ValueError, UnicodeError):
                    pass
                entry['upstream_status'] = status
                record(entry)
                self.reply(503, json.dumps({
                    'error': 'Provider failed upstream' + (': ' + detail.decode('utf-8', 'replace') if detail else ''),
                    'upstream_status': status,
                }).encode())
            elif status >= 400:
                record(entry)
                # Keep the provider's own wording; a client shows it verbatim.
                if data.startswith(b'{'):
                    self.reply(status, data)
                else:
                    self.reply(status, b'{"error":"Provider request failed","status":'
                               + str(status).encode() + b'}')
            else:
                record(entry)
                self.reply(status, data)
        except (ValueError, UnicodeError):
            entry['status'] = 400
            record(entry)
            self.reply(400, b'{"error":"Invalid JSON request"}')
        except (OSError, http.client.HTTPException) as exc:
            # 503 rather than 504: Cloudflare masks 504 with its own HTML page.
            entry['status'] = 503
            entry['error'] = type(exc).__name__
            record(entry)
            self.reply(503, b'{"error":"Upstream connection failed or timed out; '
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
