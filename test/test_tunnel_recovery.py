"""Run the production recovery function with process/service boundaries stubbed."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


class TunnelRecoveryTests(unittest.TestCase):
    def test_restart_escalates_only_the_original_stuck_connector(self):
        source = Path('watch-gateway.sh').read_text()
        function = re.search(r'^restart_tunnel\(\) \{\n.*?^\}', source, re.M | re.S).group()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            starter = root / 'start-gateway.sh'
            starter.write_text('#!/bin/sh\ntouch "$ROOT/recovered"\n')
            starter.chmod(0o700)
            script = '''
log() { :; }
sleep() { touch "$ROOT/replacement-started"; }
pgrep() {
    printf '31001\\n'
    [ ! -f "$ROOT/replacement-started" ] || printf '31002\\n'
}
kill() {
    [ "$1" != '-0' ] || return 0
    printf '%s\\n' "$*" >> "$ROOT/signals"
}
PORT=8792
WATCH_LOG="$ROOT/watch.log"
''' + function + '\nrestart_tunnel\n'
            subprocess.run(['bash', '-c', script], env={**os.environ, 'ROOT': directory}, check=True)
            signals = (root / 'signals').read_text().splitlines()
            self.assertIn('-KILL 31001', signals, 'stuck graceful shutdown is never escalated')
            self.assertNotIn('-KILL 31002', signals, 'recovery kills the replacement connector')
            self.assertTrue((root / 'recovered').exists())

    def test_restart_targets_connector_not_supervisor_and_restores_stack(self):
        source = Path('watch-gateway.sh').read_text()
        function = re.search(r'^restart_tunnel\(\) \{\n.*?^\}', source, re.M | re.S).group()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            starter = root / 'start-gateway.sh'
            starter.write_text('#!/bin/sh\ntouch "$ROOT/recovered"\n')
            starter.chmod(0o700)
            script = '''
log() { :; }
sleep() { :; }
pgrep() { printf '%s\\n' "$2" > "$ROOT/pattern"; }
PORT=8792
WATCH_LOG="$ROOT/watch.log"
''' + function + '\nrestart_tunnel\n'
            subprocess.run(['bash', '-c', script], env={**os.environ, 'ROOT': directory}, check=True)
            pattern = (root / 'pattern').read_text().strip()
            child = '/root/.local/bin/cloudflared tunnel --url http://127.0.0.1:8792 --no-autoupdate'
            supervisor = 'bash -c while true; do ' + child + '; sleep 5; done'
            self.assertIsNotNone(re.search(pattern, child), 'connector was not targeted')
            self.assertIsNone(re.search(pattern, supervisor), 'restart kills its own supervisor')
            self.assertTrue((root / 'recovered').exists(), 'dead supervisor was never restored')


if __name__ == '__main__':
    unittest.main()
