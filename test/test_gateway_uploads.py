import json
import socket
import time
import unittest
from contextlib import contextmanager
from threading import Event, Thread
from unittest.mock import Mock, patch

import test_gateway


class GatewayUploadTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_gateway.GatewayTests()
        self.module = self.fixture.load_gateway()
        self.forwarded = []
        self.entries = []

    @contextmanager
    def server(self):
        def upstream(*args, **kwargs):
            connection = Mock()
            connection.request.side_effect = lambda method, path, body, headers: self.forwarded.append(
                json.loads(body))
            connection.getresponse.return_value.status = 200
            connection.getresponse.return_value.read.return_value = (
                b'{"choices":[{"message":{"content":"fixture reply"}}]}')
            return connection

        with patch.object(self.module.http.client, 'HTTPConnection', side_effect=upstream), \
                patch.object(self.module, 'record', side_effect=lambda entry: self.entries.append(dict(entry))):
            from http.server import ThreadingHTTPServer
            from threading import Thread
            server = ThreadingHTTPServer(('127.0.0.1', 0), self.module.Handler)
            server.token = 'gateway-fixture'
            worker = Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                yield server
            finally:
                server.shutdown()
                server.server_close()
                worker.join(timeout=3)

    def upload(self, server, body, headers=None, chunked=False, eof=False):
        connection = test_gateway.CLIENT_CONNECTION(*server.server_address, timeout=3)
        try:
            connection.putrequest('POST', '/v1/chat/completions')
            connection.putheader('Authorization', 'Bearer gateway-fixture')
            connection.putheader('Content-Type', 'application/json')
            for name, value in headers or []:
                connection.putheader(name, value)
            connection.endheaders(body, encode_chunked=chunked)
            if eof:
                connection.sock.shutdown(socket.SHUT_WR)
            response = connection.getresponse()
            return response.status, json.loads(response.read()), dict(response.getheaders())
        finally:
            connection.close()

    def test_large_valid_json_reaches_provider_and_logs_only_transfer_metadata(self):
        marker = 'private-prompt-must-not-appear-in-access-log'
        payload = {'model': 'fixture-model', 'messages': [{'role': 'user', 'content': marker}], 'stream': True}
        body = json.dumps(payload).encode() + b' ' * (3 * 1024 * 1024)
        with self.server() as server:
            status, _, headers = self.upload(server, body, [('Content-Length', str(len(body)))])
        self.assertEqual(status, 200)
        self.assertEqual(self.forwarded, [{**payload, 'stream': False}])
        entry = self.entries[-1]
        self.assertEqual(entry['request_bytes'], len(body))
        self.assertEqual(entry['declared_bytes'], len(body))
        self.assertEqual(entry['request_framing'], 'content-length')
        self.assertEqual(entry['event'], 'gateway_request')
        self.assertEqual(headers['X-UAI-Request-Id'], entry['request_id'])
        self.assertNotIn(marker, json.dumps(self.entries))
        self.assertNotIn('gateway-fixture', json.dumps(self.entries))

    def test_valid_chunked_json_is_decoded_before_forwarding(self):
        body = json.dumps({'model': 'fixture-model', 'messages': []}).encode()
        with self.server() as server:
            status, _, _ = self.upload(server, iter([body[:9], body[9:]]),
                                       [('Transfer-Encoding', 'chunked')], chunked=True)
        self.assertEqual(status, 200)
        self.assertEqual(len(self.forwarded), 1)
        self.assertEqual(self.forwarded[0]['model'], 'fixture-model')
        self.assertEqual(self.entries[-1]['request_framing'], 'chunked')
        self.assertEqual(self.entries[-1]['request_bytes'], len(body))

    def test_chunk_extensions_and_bounded_trailers_do_not_become_provider_headers(self):
        wire = b'2;fixture=yes\r\n{}\r\n0\r\nX-Fixture: ignored\r\n\r\n'
        with self.server() as server:
            status, _, _ = self.upload(server, wire, [('Transfer-Encoding', 'chunked')])
        self.assertEqual(status, 200)
        self.assertEqual(self.forwarded, [{'stream': False}])

    def test_ambiguous_or_invalid_framing_is_rejected_without_forwarding(self):
        cases = [
            [('Content-Length', '2'), ('Transfer-Encoding', 'chunked')],
            [('Content-Length', '2'), ('Content-Length', '2')],
            [('Content-Length', '2, 2')],
            [('Content-Length', '-1')],
            [('Content-Length', '+2')],
            [('Transfer-Encoding', 'gzip, chunked')],
            [('Transfer-Encoding', 'chunked'), ('Transfer-Encoding', 'chunked')],
        ]
        with self.server() as server:
            for framing in cases:
                with self.subTest(framing=framing):
                    status, body, headers = self.upload(server, b'{}', framing, eof=True)
                    self.assertEqual(status, 400)
                    self.assertEqual(body['code'], 'invalid_request_framing')
                    self.assertEqual(headers.get('Connection'), 'close')
        self.assertEqual(self.forwarded, [])

    def test_declared_body_over_limit_is_rejected_without_reading_or_forwarding(self):
        with patch.object(self.module, 'MAX_BODY', 128), self.server() as server:
            status, body, headers = self.upload(server, b'', [('Content-Length', '129')])
        self.assertEqual(status, 413)
        self.assertEqual(body['code'], 'request_too_large')
        self.assertEqual(body['limit_bytes'], 128)
        self.assertEqual(headers.get('Connection'), 'close')
        self.assertEqual(self.entries[-1]['error_code'], 'request_too_large')
        self.assertEqual(self.entries[-1]['declared_bytes'], 129)
        self.assertEqual(self.forwarded, [])

    def test_chunked_body_uses_same_decoded_size_limit(self):
        with patch.object(self.module, 'MAX_BODY', 128), self.server() as server:
            status, body, headers = self.upload(server, iter([b' ' * 129]),
                                               [('Transfer-Encoding', 'chunked')], chunked=True)
        self.assertEqual(status, 413)
        self.assertEqual(body['code'], 'request_too_large')
        self.assertEqual(headers.get('Connection'), 'close')
        self.assertEqual(self.forwarded, [])

    def test_malformed_chunking_and_truncated_bodies_fail_as_upload_errors(self):
        cases = [
            (b'Z\r\n{}\r\n0\r\n\r\n', [('Transfer-Encoding', 'chunked')]),
            (b'2\r\n{}XX0\r\n\r\n', [('Transfer-Encoding', 'chunked')]),
            (b'2\r\n{}\r\n0\r\nContent-Length: 2\r\n\r\n', [('Transfer-Encoding', 'chunked')]),
            (b'{}', [('Content-Length', '100')]),
        ]
        with self.server() as server:
            for wire, framing in cases:
                with self.subTest(wire=wire):
                    status, body, headers = self.upload(server, wire, framing, eof=True)
                    self.assertEqual(status, 400)
                    self.assertIn(body['code'], ('invalid_request_framing', 'incomplete_request_body'))
                    self.assertEqual(headers.get('Connection'), 'close')
        self.assertEqual(self.forwarded, [])

    def test_unauthorized_post_closes_without_consuming_an_untrusted_body(self):
        with self.server() as server:
            connection = test_gateway.CLIENT_CONNECTION(*server.server_address, timeout=3)
            try:
                connection.request('POST', '/v1/chat/completions', b'private request',
                                   {'Authorization': 'Bearer wrong'})
                response = connection.getresponse()
                response.read()
                self.assertEqual(response.status, 403)
                self.assertEqual(response.getheader('Connection'), 'close')
            finally:
                connection.close()
        self.assertEqual(self.forwarded, [])

    def test_continuous_slow_upload_cannot_extend_the_absolute_read_deadline(self):
        read_body = self.module.read_request_body
        for framing, fragment in [([('Content-Length', '1000')], b' '),
                                  ([('Transfer-Encoding', 'chunked')], b'1')]:
            with self.subTest(framing=framing), \
                    patch.object(self.module, 'read_request_body',
                                 side_effect=lambda *args: read_body(*args, budget=0.2)), \
                    self.server() as server:
                connection = test_gateway.CLIENT_CONNECTION(*server.server_address, timeout=3)
                stop = Event()

                def drip():
                    try:
                        for _ in range(20):
                            if stop.wait(0.05):
                                break
                            connection.send(fragment)
                    except OSError:
                        pass  # The bounded reader closes a rejected connection.

                sender = None
                try:
                    connection.putrequest('POST', '/v1/chat/completions')
                    connection.putheader('Authorization', 'Bearer gateway-fixture')
                    for name, value in framing:
                        connection.putheader(name, value)
                    connection.endheaders()
                    started = time.monotonic()
                    sender = Thread(target=drip, daemon=True)
                    sender.start()
                    response = connection.getresponse()
                    body = json.loads(response.read())
                    elapsed = time.monotonic() - started
                    self.assertEqual(response.status, 408)
                    self.assertEqual(body['code'], 'request_upload_timeout')
                    self.assertLess(elapsed, 0.8, 'continual bytes extended the absolute upload deadline')
                finally:
                    stop.set()
                    if sender:
                        sender.join(timeout=2)
                    connection.close()
        self.assertEqual(self.forwarded, [])


if __name__ == '__main__':
    unittest.main()
