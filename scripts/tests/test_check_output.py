"""Failure injection for the real Mac test entry point; no Xcode, VM or key needed."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MOCK = '''#!/usr/bin/env python3
import os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['CHECK_CALLS'], 'a') as f: f.write(name + ' ' + ' '.join(args) + '\\n')
stage = ('unit' if name == 'swift' and args[0] == 'test' else
         'build' if name == 'xcodebuild' else
         'selftest' if name == 'cc-harness' and args[0] == 'vm' else
         args[-1] if name == 'cc-harness' else name)
if stage == os.environ.get('CHECK_FAIL'):
    print('BUILD FAILED' if stage == 'build' else 'diagnostic without a filter match')
    sys.exit(int(os.environ.get('CHECK_STATUS', '42')))
if name == 'swift' and '--show-bin-path' in args: print(os.path.dirname(sys.argv[0]))
if name == 'codesign' and '-d' in args: print('<key>com.apple.security.virtualization</key>')
if name == 'cc-harness': print('PASS')
'''


class MacChecks(unittest.TestCase):
    def run_checks(self, stage='', status=42, live=False):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            for name in ['swift', 'xcodegen', 'xcodebuild', 'codesign', 'cc-harness']:
                tool = path / name
                tool.write_text(MOCK)
                tool.chmod(0o755)
            env = os.environ.copy()
            env.update(PATH=tmp + os.pathsep + env['PATH'], CHECK_CALLS=str(path / 'calls'),
                       CHECK_FAIL=stage, CHECK_STATUS=str(status), CC_TEST_LOG_DIR=str(path / 'logs'))
            env.pop('CC_API_KEY', None)
            if live:
                env['CC_API_KEY'] = 'fake-test-key'
            result = subprocess.run(['/bin/sh', str(ROOT / 'scripts/test-mac.sh')],
                                    env=env, capture_output=True, text=True)
            return result, (path / 'calls').read_text()

    def test_unit_failure_is_not_hidden_by_filter(self):
        result, calls = self.run_checks('unit')
        self.assertEqual(result.returncode, 42)
        self.assertIn('diagnostic without a filter match', result.stderr)
        self.assertNotIn('xcodebuild', calls)

    def test_failed_build_marker_cannot_pass(self):
        result, calls = self.run_checks('build', status=65)
        self.assertEqual(result.returncode, 65)
        self.assertIn('BUILD FAILED', result.stderr)
        self.assertNotIn('cc-harness', calls)

    def test_timeout_exit_propagates(self):
        result, _ = self.run_checks('selftest', status=124)
        self.assertEqual(result.returncode, 124)

    def test_live_scenario_failure_stops_the_run(self):
        result, calls = self.run_checks('approval', live=True)
        self.assertEqual(result.returncode, 42)
        self.assertNotIn('--scenario injection', calls)

    def test_missing_signing_tool_is_a_failure(self):
        result, calls = self.run_checks('codesign', status=127)
        self.assertEqual(result.returncode, 127)
        self.assertNotIn('cc-harness', calls)

    def test_success_without_filter_matches_and_explicit_skip(self):
        result, _ = self.run_checks()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('skipped (CC_API_KEY not set)', result.stdout)

    def test_all_live_checks_run(self):
        result, calls = self.run_checks(live=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--scenario injection', calls)


if __name__ == '__main__':
    unittest.main()
