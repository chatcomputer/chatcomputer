import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'regress/guest_readiness.py'
spec = importlib.util.spec_from_file_location('guest_readiness_probe', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class GuestReadiness(unittest.TestCase):
    def test_actual_ready_version(self):
        for version in ['0.9.11 (43)', '0.9.12 (73)']:
            with self.subTest(version=version):
                status = f'Virtual Mac: running, desktop ready\nAgent in the virtual Mac: {version}\n'
                self.assertEqual(module.ready_guest_version(status), version)

    def test_mismatch_hint_cannot_be_an_actual_version(self):
        status = ('Virtual Mac: running, desktop ready\n'
                  'Agent in the virtual Mac: 0.9.12 (73) '
                  '(this app brings 0.9.11 (43); it updates when the virtual Mac is idle)\n')
        self.assertIsNone(module.ready_guest_version(status))

    def test_missing_or_ambiguous_agent_cannot_be_ready(self):
        for suffix in ['', 'Agent in the virtual Mac: unknown\n',
                       'Agent in the virtual Mac: 0.9.11 (43)\nAgent in the virtual Mac: 0.9.12 (73)\n']:
            with self.subTest(suffix=suffix):
                self.assertIsNone(module.ready_guest_version('Virtual Mac: running, desktop ready\n' + suffix))

    def test_not_ready_cannot_be_accepted_from_other_text(self):
        for state in ['Virtual Mac: stopped', 'Virtual Mac: running, capture not verified',
                      'Virtual Mac: running, agent not connected']:
            with self.subTest(state=state):
                self.assertIsNone(module.ready_guest_version(
                    state + '\nAgent in the virtual Mac: 0.9.11 (43)\nSnapshots: 1, current “desktop ready”\n'))

    def test_crlf_and_startup_notice_do_not_change_the_actual_version(self):
        self.assertEqual(module.ready_guest_version(
            'Starting Chat Computer…\r\nVirtual Mac: running, desktop ready\r\n'
            'Agent in the virtual Mac: 0.9.11 (43)\r\n'), '0.9.11 (43)')


if __name__ == '__main__': unittest.main()
