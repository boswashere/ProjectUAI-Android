import importlib.util
import unittest
from pathlib import Path


class GatewayTests(unittest.TestCase):
    def test_routes_and_auth(self):
        spec = importlib.util.spec_from_file_location('gateway', Path(__file__).parents[1] / 'gateway.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(module.allowed('GET', '/v1/models', 'Bearer secret', 'secret'))
        self.assertTrue(module.allowed('POST', '/v1/chat/completions', 'Bearer secret', 'secret'))
        for method, path, auth in [('GET', '/api/data', 'Bearer secret'), ('GET', '/v1/models', ''), ('POST', '/api/opencode/session', 'Bearer secret'), ('GET', '/v1/models?x=1', 'Bearer secret')]:
            self.assertFalse(module.allowed(method, path, auth, 'secret'))


if __name__ == '__main__':
    unittest.main()
