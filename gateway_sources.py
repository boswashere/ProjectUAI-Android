"""Read existing provider configuration without exporting credentials to clients."""
import json
import os
from pathlib import Path
import re
import subprocess
from threading import Lock
import time

CONFIG_FILE = Path('/root/.config/opencode/opencode.json')
_KEY_PROVIDERS = frozenset({'fcc', 'rsiai', 'hinoki'})
_credentials = {}
_credentials_until = 0
_credentials_lock = Lock()


def configuration():
    try:
        value = json.loads(CONFIG_FILE.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError, UnicodeError):
        return {}


def _provider(provider_id):
    providers = configuration().get('providers')
    value = providers.get(provider_id) if isinstance(providers, dict) else None
    return value if isinstance(value, dict) else {}


def _clean_key(value):
    if not isinstance(value, str):
        return ''
    value = value.strip()
    return value if len(value) <= 16384 and '\r' not in value and '\n' not in value else ''


def _configured_key(value):
    if not isinstance(value, str):
        return ''
    if value.startswith('{file:') and value.endswith('}'):
        try:
            return _clean_key(Path(value[6:-1]).expanduser().read_text())
        except (OSError, UnicodeError):
            return ''
    if value.startswith('{env:') and value.endswith('}'):
        return _clean_key(os.environ.get(value[5:-1], ''))
    if value.startswith('{'):
        return ''
    return _clean_key(value)


def _stored_hinoki_key():
    global _credentials, _credentials_until
    with _credentials_lock:
        if time.monotonic() >= _credentials_until:
            keys = {}
            try:
                result = subprocess.run(
                    ['opencode', 'api', 'get', '/api/credential'],
                    capture_output=True, text=True, timeout=6, check=False)
                response = json.loads(result.stdout) if result.returncode == 0 else {}
                entries = response.get('data') if isinstance(response, dict) else None
                for entry in entries if isinstance(entries, list) else []:
                    if not isinstance(entry, dict):
                        continue
                    value = entry.get('value', {})
                    if entry.get('integrationID') == 'hinoki' and entry.get('active') is True \
                            and isinstance(value, dict) and value.get('type') == 'key':
                        key = _clean_key(value.get('key'))
                        if key:
                            keys['hinoki'] = key
            except (OSError, ValueError, AttributeError, subprocess.TimeoutExpired):
                pass
            _credentials, _credentials_until = keys, time.monotonic() + 60
        return _credentials.get('hinoki', '')


class ProviderKey:
    """File-like read interface; the secret is resolved only on this server."""

    def __init__(self, provider_id):
        self.provider_id = provider_id

    def read_text(self):
        if self.provider_id not in _KEY_PROVIDERS:
            return ''
        provider = _provider(self.provider_id)
        settings = provider.get('settings')
        key = _configured_key(settings.get('apiKey') if isinstance(settings, dict) else None)
        if key:
            return key
        names = provider.get('env')
        for name in names if isinstance(names, list) else []:
            if isinstance(name, str):
                key = _clean_key(os.environ.get(name, ''))
                if key:
                    return key
        return _stored_hinoki_key() if self.provider_id == 'hinoki' else ''


def configured_models(provider_id):
    """Public model IDs only: no settings, credentials, limits or private URLs."""
    provider = _provider(provider_id)
    models = provider.get('models', {})
    if not isinstance(models, dict):
        return []
    result = []
    for name, metadata in models.items():
        wire_id = metadata.get('modelID', name) if isinstance(metadata, dict) else name
        if isinstance(wire_id, str) and 0 < len(wire_id) <= 256 \
                and re.fullmatch(r'[A-Za-z0-9_./:+-]+', wire_id) and wire_id not in result:
            result.append(wire_id)
        if len(result) == 512:
            break
    return result
