"""The install entry point must reject existing isolated data before any changes."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class FreshInstallIsolation(unittest.TestCase):
    def refused(self, kind):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / 'existing test data'
            if kind == 'directory':
                target.mkdir()
                (target / 'keep.txt').write_text('keep original')
            elif kind == 'file':
                target.write_text('keep original')
            else:
                target.symlink_to(root / 'missing destination')
            archive = root / 'candidate.zip'
            archive.write_bytes(b'not used: rejection must precede extraction')
            tools = root / 'bin'
            tools.mkdir()
            calls = root / 'unexpected-calls'
            for name in ['defaults', 'open', 'ditto', 'xattr', 'spctl', 'mv', 'rm', 'pgrep']:
                fake = tools / name
                fake.write_text('#!/bin/sh\necho unexpected >> "$FRESH_CALLS"\nexit 99\n')
                fake.chmod(0o755)
            env = dict(os.environ, CC_DATA_DIR=str(target), FRESH_CALLS=str(calls),
                       PATH=str(tools) + os.pathsep + os.environ['PATH'])
            result = subprocess.run(['/bin/sh', str(ROOT / 'scripts/fresh-install.sh'), str(archive)],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('isolated test folder must not exist', result.stderr + result.stdout)
            self.assertFalse(calls.exists(), 'No preferences, process, or data changes are allowed on rejection')
            if kind == 'directory':
                self.assertEqual((target / 'keep.txt').read_text(), 'keep original')
            elif kind == 'file':
                self.assertEqual(target.read_text(), 'keep original')
            else:
                self.assertTrue(target.is_symlink())
                self.assertFalse((root / 'missing destination').exists())

    def test_existing_directory_is_preserved(self):
        self.refused('directory')

    def test_existing_file_is_preserved(self):
        self.refused('file')

    def test_dangling_symlink_is_preserved(self):
        self.refused('symlink')


if __name__ == '__main__':
    unittest.main()
