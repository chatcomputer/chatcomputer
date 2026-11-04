import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('soak', Path(__file__).resolve().parents[1] / 'soak.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SoakLaunch(unittest.TestCase):
    def test_launch_and_resume_keep_the_isolated_vm_without_forwarding_keys(self):
        with patch.dict(os.environ, {'CC_DATA_DIR': '/tmp/isolated test', 'CC_API_KEY': 'test-only-do-not-forward'}), \
                patch.object(module.subprocess, 'run') as run, \
                patch.object(module, 'status', return_value='desktop ready'):
            for cont in [False, True]:
                self.assertTrue(module.launch('/tmp/Test App.app', cont))
                args = run.call_args.args[0]
                self.assertIn('CC_DATA_DIR=/tmp/isolated test', args)
                self.assertNotIn('CC_API_KEY=test-only-do-not-forward', args)
                self.assertEqual('CC_DEV_CONTINUE=1' in args, cont)


if __name__ == '__main__': unittest.main()
