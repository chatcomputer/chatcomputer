from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class OnboardingFailure(unittest.TestCase):
    def detected(self, text):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp, 'onboarding.log');log.write_text(text)
            return subprocess.run(['/bin/sh', '-c', '. "$1"; onboarding_failed "$2"', 'test',
                                   str(ROOT / 'scripts/check-output.sh'), str(log)]).returncode == 0

    def test_permission_setup_failure_does_not_wait_for_ninety_minutes(self):
        self.assertTrue(self.detected('2026-11-04T13:03:22Z permission: setup-failed\n'))

    def test_cancelled_setup_is_not_a_successful_install(self):
        self.assertTrue(self.detected('permission: setup-cancelled\n'))

    def test_other_onboarding_failures_still_stop(self):
        self.assertTrue(self.detected('onboarding: installMacOS failed: example\n'))

    def test_in_progress_capture_and_success_are_not_failures(self):
        self.assertFalse(self.detected('permission: capture-probe-not-yet-visible\npermission: capture-verification-passed\n'))


if __name__ == '__main__':
    unittest.main()
