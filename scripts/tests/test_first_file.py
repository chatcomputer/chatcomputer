import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('first_file', Path(__file__).resolve().parents[1] / 'check-first-file.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FirstFile(unittest.TestCase):
    def test_wrong_content_or_missing_file_does_not_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, 'note.txt').write_text('wrong')
            with self.assertRaises(ValueError): module.verify(tmp, 'note.txt', 'correct')
            with self.assertRaises(ValueError): module.verify(tmp, 'missing.txt', 'correct')

    def test_utf8_and_utf16_are_checked_on_host(self):
        for encoding in ('utf-8', 'utf-16'):
            with tempfile.TemporaryDirectory() as tmp:
                folder = Path(tmp, 'task')
                folder.mkdir()
                (folder / 'note.txt').write_text('expected\n', encoding=encoding)
                module.verify(tmp, 'note.txt', 'expected')

    def test_symlink_cannot_stand_in_for_a_deliverable(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp, 'outbox')
            root.mkdir()
            outside = Path(tmp, 'outside.txt')
            outside.write_text('expected')
            (root / 'note.txt').symlink_to(outside)
            with self.assertRaises(ValueError): module.verify(root, 'note.txt', 'expected')


if __name__ == '__main__': unittest.main()
