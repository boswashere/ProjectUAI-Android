import importlib.util
import http.client
from http.server import ThreadingHTTPServer
from threading import Thread
import unittest
from unittest.mock import patch
from pathlib import Path


class GatewayTests(unittest.TestCase):
    def test_routes_and_auth(self):
        spec = importlib.util.spec_from_file_location('gateway', Path(__file__).parents[1] / 'gateway.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(module.allowed('GET', '/v1/models'))
        self.assertTrue(module.allowed('POST', '/v1/chat/completions'))
        for method, path in [('GET', '/api/data'), ('POST', '/api/opencode/session'), ('GET', '/v1/models?x=1')]:
            self.assertFalse(module.allowed(method, path))

        # Authentication now lives in Handler.forward, not allowed(). Exercise
        # that boundary without making a paid or external provider request.
        server = ThreadingHTTPServer(('127.0.0.1', 0), module.Handler)
        server.token = 'fixture-secret'
        worker = Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            with patch.object(module, 'record'):
                for auth, expected in [('', 403), ('Bearer wrong', 403), ('Bearer fixture-secret', 404)]:
                    connection = http.client.HTTPConnection(*server.server_address, timeout=3)
                    try:
                        connection.request('GET', '/unknown', headers={'Authorization': auth})
                        response = connection.getresponse()
                        self.assertEqual(response.status, expected)
                        response.read()
                    finally:
                        connection.close()
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=3)


if __name__ == '__main__':
    unittest.main()
