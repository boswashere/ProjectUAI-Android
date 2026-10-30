"""Authenticated multi-provider inference gateway for the local model pools.

One bearer token fronts every upstream, so an Android Roblox client needs a
single URL and one secret. Only model listing and chat completions are exposed;
provider keys stay on this host.

Routes:

  /v1/models, /v1/chat/completions            local VibeCode pool (127.0.0.1:8787)
  /gonka/v1/models, /gonka/v1/chat/completions  GonkaRouter (GLM, DeepSeek, MiniMax)
  /zen/v1/models, /zen/v1/chat/completions      OpenCode Zen (only with a key on disk)

`GET /routes` lists the prefixes that are live, so the Android loader only
creates providers this host can actually serve.

Replies are non-streaming because Cloudflare Quick Tunnels do not carry SSE.
"""
import hmac
import http.client
import json
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import BoundedSemaphore

TOKEN_FILE = Path('/root/.secrets/uai-gateway-token')
GONKA_KEY_FILE = Path('/root/.secrets/gonkarouter-key')
ZEN_KEY_FILE = Path('/root/.secrets/zen-key')
SLOTS = BoundedSemaphore(4)
MAX_BODY = 2 * 1024 * 1024
MAX_REPLY = 16 * 1024 * 1024
UPSTREAM_TIMEOUT = 95

# prefix, host, port, tls, key file, upstream path prefix, needs a key
ROUTES = (
    ('/v1/', '127.0.0.1', 8787, False, None, '/v1/', False),
    ('/gonka/v1/', 'api.gonkarouter.io', 443, True, GONKA_KEY_FILE, '/v1/', True),
    ('/zen/v1/', 'opencode.ai', 443, True, ZEN_KEY_FILE, '/v1/', True),
)


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


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def reply(self, status, body):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/routes':
            body = json.dumps({'routes': [route[0].rstrip('/') for route in active_routes()]}).encode()
            self.reply(200, body)
            return
        self.forward()

    def do_POST(self):
        self.forward()

    def forward(self):
        authorization = self.headers.get('Authorization', '')
        if not self.server.token or not hmac.compare_digest(
                authorization.encode(), ('Bearer ' + self.server.token).encode()):
            self.reply(403, b'{"error":"Access denied"}')
            return
        route = route_for(self.path)
        if not route or not allowed(self.command, self.path):
            self.reply(404, b'{"error":"Unknown route"}')
            return
        if not SLOTS.acquire(blocking=False):
            self.reply(429, b'{"error":"Gateway busy"}')
            return
        upstream = None
        try:
            self.connection.settimeout(30)
            length = int(self.headers.get('Content-Length', '0'))
            if self.headers.get('Transfer-Encoding') or not 0 <= length <= MAX_BODY:
                self.reply(413, b'{"error":"Invalid request size"}')
                return
            body = None
            if self.command == 'POST':
                payload = json.loads(self.rfile.read(length))
                if not isinstance(payload, dict):
                    raise ValueError('Expected object')
                payload['stream'] = False
                payload.pop('stream_options', None)
                body = json.dumps(payload).encode()

            _, host, port, tls, key_file, upstream_path = route
            headers = {'Content-Type': 'application/json'}
            if key_file:
                key = key_file.read_text().strip()
                if not key:
                    self.reply(503, b'{"error":"Upstream credential missing"}')
                    return
                headers['Authorization'] = 'Bearer ' + key

            if tls:
                upstream = http.client.HTTPSConnection(host, port, timeout=UPSTREAM_TIMEOUT,
                                                       context=ssl.create_default_context())
            else:
                upstream = http.client.HTTPConnection(host, port, timeout=UPSTREAM_TIMEOUT)
            upstream.request(self.command, upstream_path, body, headers)
            response = upstream.getresponse()
            data = response.read(MAX_REPLY + 1)
            if len(data) > MAX_REPLY:
                self.reply(502, b'{"error":"Response too large"}')
            elif response.status >= 400:
                self.reply(response.status, b'{"error":"Provider request failed","status":'
                           + str(response.status).encode() + b'}')
            else:
                self.reply(response.status, data)
        except (ValueError, UnicodeError):
            self.reply(400, b'{"error":"Invalid JSON request"}')
        except (OSError, http.client.HTTPException):
            self.reply(504, b'{"error":"Upstream connection failed or timed out; request was not replayed"}')
        finally:
            if upstream:
                upstream.close()
            SLOTS.release()


if __name__ == '__main__':
    server = ThreadingHTTPServer(('127.0.0.1', 8792), Handler)
    server.token = TOKEN_FILE.read_text().strip()
    if len(server.token) < 32:
        raise SystemExit('Gateway token must have at least 32 characters')
    server.serve_forever()
