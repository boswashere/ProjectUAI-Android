"""Authenticated inference-only gateway for the local VibeCode pool."""
import hmac
import http.client
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import BoundedSemaphore

TOKEN_FILE = Path('/root/.secrets/uai-gateway-token')
SLOTS = BoundedSemaphore(4)


def allowed(method, path, authorization, token):
    return bool(token) and hmac.compare_digest(authorization.encode(), ('Bearer ' + token).encode()) and (method, path) in {
        ('GET', '/v1/models'), ('POST', '/v1/chat/completions')}


class Handler(BaseHTTPRequestHandler):
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
        self.forward()

    def do_POST(self):
        self.forward()

    def forward(self):
        if not allowed(self.command, self.path, self.headers.get('Authorization', ''), self.server.token):
            self.reply(403, b'{"error":"Access denied"}')
            return
        if not SLOTS.acquire(blocking=False):
            self.reply(429, b'{"error":"Gateway busy"}')
            return
        upstream = None
        try:
            self.connection.settimeout(30)
            length = int(self.headers.get('Content-Length', '0'))
            if self.headers.get('Transfer-Encoding') or not 0 <= length <= 2 * 1024 * 1024:
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
            upstream = http.client.HTTPConnection('127.0.0.1', 8787, timeout=110)
            upstream.request(self.command, self.path, body, {'Content-Type': 'application/json'})
            response = upstream.getresponse()
            data = response.read(16 * 1024 * 1024 + 1)
            if len(data) > 16 * 1024 * 1024:
                self.reply(502, b'{"error":"Response too large"}')
            elif response.status >= 400:
                self.reply(response.status, b'{"error":"Provider request failed"}')
            else:
                self.reply(response.status, data)
        except (ValueError, UnicodeError):
            self.reply(400, b'{"error":"Invalid JSON request"}')
        except (OSError, http.client.HTTPException):
            self.reply(502, b'{"error":"Upstream connection failed; request was not replayed"}')
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
