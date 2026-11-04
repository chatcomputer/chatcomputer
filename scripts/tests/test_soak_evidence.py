import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'soak.py'
spec = importlib.util.spec_from_file_location('soak_evidence', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Clock:
    now = 0

    def sleep(self, seconds):
        self.now += seconds


class SoakEvidence(unittest.TestCase):
    def test_snapshot_needs_positive_evidence_and_no_error(self):
        self.assertFalse(module.response_succeeded({}, 'Saved snapshot'))
        self.assertFalse(module.response_succeeded({'text': 'Saved snapshot', 'isError': True}, 'Saved snapshot'))
        self.assertTrue(module.response_succeeded({'text': 'Saved snapshot “Soak”.', 'isError': False}, 'Saved snapshot'))

    def test_old_completed_task_cannot_satisfy_a_new_submission(self):
        clock = Clock()
        with patch.object(module, 'task_ids', return_value={'old'}), \
                patch.object(module, 'read_task', return_value={'phase': 'completed', 'goal': 'task'}), \
                patch.object(module.time, 'monotonic', side_effect=lambda: clock.now), \
                patch.object(module.time, 'sleep', side_effect=clock.sleep):
            self.assertIsNone(module.wait_new_task('task', {'old'}, limit=3))

    def test_unrelated_new_task_cannot_satisfy_the_requested_goal(self):
        clock = Clock()
        with patch.object(module, 'task_ids', return_value={'other'}), \
                patch.object(module, 'read_task', return_value={'phase': 'completed', 'goal': 'unrelated'}), \
                patch.object(module.time, 'monotonic', side_effect=lambda: clock.now), \
                patch.object(module.time, 'sleep', side_effect=clock.sleep):
            self.assertIsNone(module.wait_new_task('task', set(), limit=3))

    def test_a_task_that_completed_between_polls_is_still_observed_by_identity(self):
        with patch.object(module, 'task_ids', return_value={'old', 'new'}), \
                patch.object(module, 'read_task', return_value={'taskID': 'new', 'phase': 'completed', 'goal': 'task', 'modelID': 'test-model', 'inputTokens': 15}):
            task_id = module.wait_new_task('task', {'old'})
            self.assertEqual(task_id, 'new')
            self.assertIsNotNone(module.wait_task(task_id))

    def test_completed_without_model_usage_or_failed_tasks_cannot_pass(self):
        for phase, tokens in [('completed', 0), ('failed', 10), ('cancelled', 10), ('waitingForUser', 10)]:
            with self.subTest(phase=phase), patch.object(module, 'read_task', return_value={'phase': phase, 'inputTokens': tokens}):
                self.assertIsNone(module.wait_task('new'))

    def test_waits_for_the_exact_task_instead_of_the_last_completed_task(self):
        clock = Clock()
        with patch.object(module, 'read_task', return_value={'phase': 'unknown'}) as read, \
                patch.object(module.time, 'monotonic', side_effect=lambda: clock.now), \
                patch.object(module.time, 'sleep', side_effect=clock.sleep):
            self.assertIsNone(module.wait_task('new', limit=3))
            self.assertTrue(all(call.args == ('new',) for call in read.call_args_list))

    def test_mismatched_persisted_identity_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(module, 'TASKS_DIR', tmp):
            folder = Path(tmp, 'new');folder.mkdir()
            (folder / 'task.json').write_text(json.dumps({'id': 'old', 'phase': {'completed': {}}, 'inputTokens': 10}))
            self.assertEqual(module.read_task('new'), {'phase': 'unknown'})

    def qualified_rows(self):
        task = {'event': 'task', 'phase': 'completed', 'taskID': 'a', 'modelID': 'test-model', 'inputTokens': 10, 'seconds': 2, 'ok': True, 'crashes': 0}
        return [task,
                {**task, 'event': 'quit-mid-task', 'taskID': 'b', 'wasBusy': True, 'phaseAtQuit': 'paused', 'quitOK': True, 'relaunchOK': True},
                {'event': 'snapshot', 'took': True, 'restored': True, 'deleted': True, 'ready': True, 'ok': True},
                {'event': 'relaunch', 'quitOK': True, 'launchOK': True, 'ok': True},
                {'event': 'done', 't': 100, 'crashes': 0}]

    def test_duration_alone_is_not_a_qualified_soak(self):
        self.assertFalse(module.qualified([{'event': 'done', 't': 100}], 100))
        rows = self.qualified_rows()
        self.assertTrue(module.qualified(rows, 100))
        self.assertFalse(module.qualified(rows, 101))
        self.assertFalse(module.qualified(rows[:-1], 1))

    def test_missing_or_failed_lifecycle_evidence_cannot_pass(self):
        for index, key, value in [(0, 'inputTokens', 0), (0, 'phase', 'failed'), (0, 'taskID', None), (0, 'modelID', None),
                                  (1, 'wasBusy', False), (1, 'quitOK', False), (1, 'relaunchOK', False),
                                  (1, 'phaseAtQuit', 'completed'),
                                  (2, 'restored', False), (2, 'deleted', False), (3, 'launchOK', False), (4, 'crashes', 1)]:
            rows = copy.deepcopy(self.qualified_rows());rows[index][key] = value
            with self.subTest(index=index, key=key):
                self.assertFalse(module.qualified(rows, 100))

    def test_invalid_duration_fails_before_launching_an_app(self):
        for value in ['0', '-1', 'nan', 'inf']:
            result = subprocess.run(['python3', str(SCRIPT), '--app', '/not-a-test-app', '--hours', value], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn('--hours', result.stderr)

    def test_no_implicit_access_to_the_users_default_vm(self):
        env = {k: v for k, v in os.environ.items() if k != 'CC_DATA_DIR'}
        result = subprocess.run(['python3', str(SCRIPT), '--app', '/not-a-test-app', '--hours', '1'], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('isolated test data', result.stderr)


if __name__ == '__main__':
    unittest.main()
