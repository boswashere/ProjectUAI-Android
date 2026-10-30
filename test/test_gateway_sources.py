import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import gateway_sources as sources


class GatewaySourcesTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.config = Path(self.directory.name) / 'config.json'
        self.config.write_text('{}')
        self.patch_config = patch.object(sources, 'CONFIG_FILE', self.config)
        self.patch_config.start()
        self.addCleanup(self.patch_config.stop)

    def write_config(self, providers):
        self.config.write_text(json.dumps({'providers': providers}))

    def test_existing_inline_file_and_environment_keys_are_read_without_changes(self):
        key_file = Path(self.directory.name) / 'key'
        key_file.write_text('fixture-file-key\n')
        self.write_config({
            'fcc': {'settings': {'apiKey': 'fixture-inline-key'}},
            'rsiai': {'settings': {'apiKey': '{file:' + str(key_file) + '}'}},
            'hinoki': {'env': ['FIXTURE_HINOKI_KEY']},
        })
        before = self.config.read_bytes()
        with patch.dict(os.environ, {'FIXTURE_HINOKI_KEY': 'fixture-env-key'}):
            self.assertEqual(sources.ProviderKey('fcc').read_text(), 'fixture-inline-key')
            self.assertEqual(sources.ProviderKey('rsiai').read_text(), 'fixture-file-key')
            self.assertEqual(sources.ProviderKey('hinoki').read_text(), 'fixture-env-key')
        self.assertEqual(self.config.read_bytes(), before)

    def test_only_active_hinoki_api_key_is_read_from_official_credential_api(self):
        self.write_config({'hinoki': {}})
        entries = [
            {'integrationID': 'hinoki', 'active': False, 'value': {'type': 'key', 'key': 'inactive-fixture'}},
            {'integrationID': 'openai', 'active': True, 'value': {'type': 'key', 'key': 'unrelated-fixture'}},
            {'integrationID': 'hinoki', 'active': True, 'value': {'type': 'oauth', 'access': 'oauth-fixture'}},
            {'integrationID': 'hinoki', 'active': True, 'value': {'type': 'key', 'key': 'active-fixture'}},
        ]
        response = subprocess.CompletedProcess([], 0, json.dumps({'data': entries}), '')
        with patch.object(sources, '_credentials_until', 0), patch.object(sources, '_credentials', {}), \
                patch.object(sources.subprocess, 'run', return_value=response) as run:
            self.assertEqual(sources.ProviderKey('hinoki').read_text(), 'active-fixture')
            self.assertEqual(sources.ProviderKey('hinoki').read_text(), 'active-fixture')
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0], ['opencode', 'api', 'get', '/api/credential'])
            self.assertEqual(sources.ProviderKey('openai').read_text(), '')

    def test_missing_keys_and_unavailable_credential_api_fail_closed(self):
        self.write_config({'rsiai': {'settings': {'apiKey': '{file:/nonexistent/fixture-key}'}}})
        with patch.object(sources, '_credentials_until', 0), patch.object(sources, '_credentials', {}), \
                patch.object(sources.subprocess, 'run', side_effect=OSError('fixture failure')):
            self.assertEqual(sources.ProviderKey('rsiai').read_text(), '')
            self.assertEqual(sources.ProviderKey('hinoki').read_text(), '')

    def test_model_metadata_uses_wire_ids_and_never_includes_settings_or_credentials(self):
        self.write_config({'fcc': {
            'settings': {'apiKey': 'private-fixture', 'baseURL': 'http://127.0.0.1:8082/v1'},
            'models': {
                'friendly': {'modelID': 'claude-fable-5', 'apiKey': 'private-fixture'},
                'duplicate': {'modelID': 'claude-fable-5'},
                'other-model': {},
                'bad\nmodel': {},
            },
        }})
        models = sources.configured_models('fcc')
        self.assertEqual(models, ['claude-fable-5', 'other-model'])
        self.assertNotIn('private-fixture', json.dumps(models))

    def test_malformed_configuration_and_credential_entries_are_ignored(self):
        self.config.write_text('{"providers":[]}')
        self.assertEqual(sources.ProviderKey('fcc').read_text(), '')
        self.assertEqual(sources.configured_models('fcc'), [])
        self.write_config({'fcc': {'settings': [], 'env': None}})
        self.assertEqual(sources.ProviderKey('fcc').read_text(), '')
        response = subprocess.CompletedProcess([], 0, json.dumps({'data': [None, 'invalid', {
            'integrationID': 'hinoki', 'active': True, 'value': {'type': 'key', 'key': 'valid-fixture'},
        }]}), '')
        with patch.object(sources, '_credentials_until', 0), patch.object(sources, '_credentials', {}), \
                patch.object(sources.subprocess, 'run', return_value=response):
            self.assertEqual(sources.ProviderKey('hinoki').read_text(), 'valid-fixture')


if __name__ == '__main__':
    unittest.main()
