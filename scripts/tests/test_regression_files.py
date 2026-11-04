"""Regress the actual stale-input/incorrect-index false pass observed in72."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'regress/external.py'
spec = importlib.util.spec_from_file_location('external_files', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
BAD_INDEX = Path(__file__).parent / 'fixtures/organize-stale-index.txt'
PATHS = ['Text/poem.txt', 'Text/letter.txt', 'Images/gradient.png', 'Data/expenses.csv']


class IsolatedInputs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.here = self.root / 'harness'
        (self.here / 'files').mkdir(parents=True)
        self.inbox = self.root / 'inbox'
        (self.inbox / 'external').mkdir(parents=True)
        (self.inbox / 'external/stale.txt').write_text('previous task')
        for name in ['first.txt', 'second.txt']:
            (self.here / 'files' / name).write_text('original ' + name)
        self.addCleanup(patch.stopall)
        patch.object(module, 'HERE', self.here).start()
        patch.object(module, 'INBOX', self.inbox).start()
        self.cli = patch.object(module, 'cli', side_effect=self.put).start()

    def put(self, args, binary):
        self.assertEqual(args[0], 'put')
        source = Path(args[1])
        shutil.copyfile(source, self.inbox / 'external' / source.name)

    def host(self, guest):
        return self.inbox / guest.rsplit('/', 1)[-1]

    def test_old_and_other_task_attachments_are_not_exposed(self):
        first, a = module.stage_attachments({'attachments': ['first.txt']}, 'product')
        second, b = module.stage_attachments({'attachments': ['second.txt']}, 'product')
        self.assertNotEqual(first, second)
        self.assertEqual([p.name for p in self.host(first).iterdir()], ['first.txt'])
        self.assertEqual([p.name for p in self.host(second).iterdir()], ['second.txt'])
        self.assertTrue((self.inbox / 'external/stale.txt').exists())
        self.assertNotEqual(a, b)
        self.assertEqual((self.host(first) / 'first.txt').read_bytes(), (self.here / 'files/first.txt').read_bytes())

    def test_repeated_same_task_gets_a_new_name_and_keeps_previous_input(self):
        task = {'attachments': ['first.txt']}
        first, _ = module.stage_attachments(task, 'product')
        second, _ = module.stage_attachments(task, 'product')
        self.assertNotEqual(first, second)
        self.assertTrue((self.host(first) / 'first.txt').exists())

    def test_no_attachments_does_not_expose_the_cumulative_folder(self):
        guest, files = module.stage_attachments({}, 'product')
        self.assertEqual(list(self.host(guest).iterdir()), [])
        self.assertEqual(files, [])
        self.cli.assert_not_called()

    def test_bad_product_ingress_stops_before_model_use(self):
        self.cli.side_effect = lambda *args: (self.inbox / 'external/first.txt').write_text('wrong bytes')
        with self.assertRaisesRegex(RuntimeError, 'differs from fixture'):
            module.stage_attachments({'attachments': ['first.txt']}, 'product')


class OutputEvidence(unittest.TestCase):
    def test_real_false_pass_index_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'index.txt'
            shutil.copyfile(BAD_INDEX, path)
            # The former contains-only check accepted this exact kind of output.
            self.assertTrue(all(Path(name).name in path.read_text() for name in PATHS))
            self.assertIn('expected paths', '; '.join(module.check_file(path, {
                'name': 'index.txt', 'contains': PATHS, 'unorderedLines': PATHS})))

    def test_utf16_index_and_arbitrary_line_order_are_valid(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'index.txt'
            path.write_bytes(('\n'.join(reversed(PATHS)) + '\n').encode('utf-16'))
            self.assertEqual(module.check_file(path, {'name': 'index.txt', 'contains': PATHS,
                                                     'unorderedLines': PATHS}), [])

    def test_duplicate_or_missing_index_entry_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'index.txt'
            path.write_text('\n'.join(PATHS + [PATHS[0]]))
            self.assertTrue(module.check_file(path, {'name': 'index.txt', 'contains': PATHS,
                                                    'unorderedLines': PATHS}))

    def test_changed_copy_cannot_pass_just_because_keywords_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'files').mkdir()
            (root / 'files/letter.txt').write_text('Dear Sam: original')
            actual = root / 'letter.txt'
            actual.write_text('Dear Sam: altered')
            with patch.object(module, 'HERE', root):
                self.assertIn('differs from', '; '.join(module.check_file(actual, {
                    'name': 'letter.txt', 'contains': ['Dear Sam'], 'sameAsAttachment': 'letter.txt'})))

    def test_unexpected_files_and_missing_files_are_not_hidden_by_other_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in PATHS + ['index.txt', 'planets.html', '.DS_Store']:
                p = root / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text('fixture')
            self.assertIn('planets.html', '; '.join(module.check_inventory(root, PATHS + ['index.txt'])))
            (root / 'planets.html').unlink()
            self.assertEqual(module.check_inventory(root, PATHS + ['index.txt']), [])
            (root / PATHS[0]).unlink()
            self.assertIn('missing', '; '.join(module.check_inventory(root, PATHS + ['index.txt'])))


if __name__ == '__main__':
    unittest.main()
