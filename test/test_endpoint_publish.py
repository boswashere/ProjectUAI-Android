"""Run actual publication code against an isolated Git repository, without pushing."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class EndpointPublicationTests(unittest.TestCase):
    def check_publication(self, script):
        text = (ROOT / script).read_text()
        if script == 'watch-gateway.sh':
            code = re.search(r'^publish\(\) \{\n.*?^\}', text, re.M | re.S).group()
            code += '\npublish "$URL"\n'
        else:
            code = text[text.index('# 5. Publish the live address.'):]
        with tempfile.TemporaryDirectory(prefix='uai publish ') as directory:
            repo = Path(directory)

            def git(*args):
                return subprocess.check_output(['git', '-C', directory, *args], text=True).strip()

            git('init', '-q')
            git('config', 'user.name', 'Fixture')
            git('config', 'user.email', 'fixture@localhost')
            (repo / 'examples').mkdir()
            artifact = 'local FALLBACK_ENDPOINT = "https://old.fixture.example"\n-- generated fixture\n'
            (repo / 'examples/gateway.lua').write_text(artifact)
            (repo / 'endpoint.txt').write_text('https://old.fixture.example\n')
            (repo / 'unrelated.txt').write_text('original\n')
            git('add', '.')
            git('commit', '-qm', 'fixture baseline')
            (repo / 'unrelated.txt').write_text('user staged work\n')
            git('add', 'unrelated.txt')
            (repo / 'fixture-pat').write_text('fixture-not-a-real-token')
            prelude = '''
set -euo pipefail
ROOT="$1"
ENDPOINT_FILE="$ROOT/endpoint.txt"
PAT_FILE="$ROOT/fixture-pat"
TOKEN_FILE="$ROOT/fixture-pat"
URL=https://next.fixture.example
MODE=quick
current_url() { cat "$ENDPOINT_FILE"; }
log() { :; }
# Delegate real staging/commits; replace only the external push boundary.
git() {
    local arg
    for arg in "$@"; do [ "$arg" != push ] || return 0; done
    command git "$@"
}
'''
            subprocess.run(['bash', '-c', prelude + code, 'fixture', directory],
                           check=True, text=True, capture_output=True)
            self.assertEqual(git('show', '--format=', '--name-only', 'HEAD'), 'endpoint.txt')
            self.assertEqual(git('diff', '--cached', '--name-only'), 'unrelated.txt')
            self.assertEqual((repo / 'examples/gateway.lua').read_text(), artifact)
            self.assertEqual((repo / 'endpoint.txt').read_text(), 'https://next.fixture.example\n')

    def test_start_publishes_only_endpoint_without_changing_artifact(self):
        self.check_publication('start-gateway.sh')

    def test_watcher_leaves_unrelated_staged_changes_untouched(self):
        self.check_publication('watch-gateway.sh')


if __name__ == '__main__':
    unittest.main()
