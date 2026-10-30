import importlib.util
import http.client
import json
from http.server import ThreadingHTTPServer
from threading import Thread
import unittest
from unittest.mock import patch
from pathlib import Path
import gateway_sources

CLIENT_CONNECTION = http.client.HTTPConnection


class GatewayTests(unittest.TestCase):
    def load_gateway(self):
        spec = importlib.util.spec_from_file_location('gateway', Path(__file__).parents[1] / 'gateway.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def serve(self, module, callback):
        server = ThreadingHTTPServer(('127.0.0.1', 0), module.Handler)
        server.token = 'gateway-fixture'
        worker = Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            return callback(server)
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=3)

    def request(self, server, method, path, auth='gateway-fixture', body=None):
        connection = CLIENT_CONNECTION(*server.server_address, timeout=3)
        try:
            connection.request(method, path, body, {
                'Authorization': 'Bearer ' + auth, 'Content-Type': 'application/json'})
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def test_new_routes_metadata_is_additive_and_contains_only_model_ids(self):
        module = self.load_gateway()
        with patch.object(module, 'has_key', return_value=True), \
                patch.object(module, 'configured_models', return_value=['fixture-wire-id'], create=True):
            status, body = self.serve(module, lambda server: self.request(server, 'GET', '/routes'))
        self.assertEqual(status, 200)
        self.assertTrue({'/v1', '/gonka/v1', '/fcc/v1', '/rsiai/v1', '/hinoki/v1'} <= set(body['routes']))
        self.assertEqual(body['providers']['/fcc/v1'], {'models': ['fixture-wire-id']})
        self.assertNotIn('apiKey', json.dumps(body))

    def test_inference_paths_are_exact_not_arbitrary_suffixes(self):
        module = self.load_gateway()
        with patch.object(module, 'has_key', return_value=True):
            for prefix in ['/v1', '/gonka/v1', '/fcc/v1', '/rsiai/v1', '/hinoki/v1']:
                self.assertTrue(module.allowed('GET', prefix + '/models'))
                self.assertTrue(module.allowed('POST', prefix + '/chat/completions'))
                self.assertFalse(module.allowed('GET', prefix + '/private/models'))
                self.assertFalse(module.allowed('POST', prefix + '/private/chat/completions'))

    def test_optional_zen_route_keeps_its_documented_upstream_prefix(self):
        module = self.load_gateway()
        with patch.object(module, 'has_key', return_value=True):
            self.assertEqual(module.route_for('/zen/v1/models')[5], '/zen/v1/models')

    def test_new_providers_use_server_keys_and_fixed_upstream_paths(self):
        module = self.load_gateway()
        forwarded = []

        def upstream(host, port, **kwargs):
            from unittest.mock import Mock
            connection = Mock()
            connection.request.side_effect = lambda method, path, body, headers: forwarded.append(
                (host, port, method, path, json.loads(body), headers))
            connection.getresponse.return_value.status = 200
            connection.getresponse.return_value.read.return_value = b'{"choices":[{"message":{"content":"fixture"}}]}'
            return connection

        def exercise(server):
            for prefix, host, port in [('/fcc/v1', '127.0.0.1', 8082),
                                       ('/rsiai/v1', 'www.rsiai.net', 443),
                                       ('/hinoki/v1', 'inference.hinoki.security', 443)]:
                payload = json.dumps({'model': 'fixture-model', 'messages': [], 'stream': True})
                denied, _ = self.request(server, 'POST', prefix + '/chat/completions', 'wrong', payload)
                self.assertEqual(denied, 403)
                status, body = self.request(server, 'POST', prefix + '/chat/completions', body=payload)
                self.assertEqual(status, 200)
                self.assertEqual(body['choices'][0]['message']['content'], 'fixture')
                actual_host, actual_port, method, path, sent, headers = forwarded[-1]
                self.assertEqual((actual_host, actual_port, method, path), (host, port, 'POST', '/v1/chat/completions'))
                self.assertEqual(headers['Authorization'], 'Bearer upstream-fixture')
                self.assertFalse(sent['stream'])
                self.assertNotIn('gateway-fixture', json.dumps(forwarded[-1]))
            self.assertEqual(len(forwarded), 3)

        with patch.object(gateway_sources.ProviderKey, 'read_text', return_value='upstream-fixture'), \
                patch.object(module.http.client, 'HTTPConnection', side_effect=upstream), \
                patch.object(module.http.client, 'HTTPSConnection', side_effect=upstream), \
                patch.object(module, 'record'):
            self.serve(module, exercise)

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
