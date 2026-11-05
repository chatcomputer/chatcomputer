import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'regress/external.py'
spec = importlib.util.spec_from_file_location('external_runner', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ExternalRunner(unittest.TestCase):
    def test_bundled_version_hint_does_not_release_the_readiness_gate(self):
        mismatch = ('Virtual Mac: running, desktop ready\n'
                    'Agent in the virtual Mac: 0.9.12 (73) '
                    '(this app brings 0.9.11 (43); it updates when the virtual Mac is idle)\n')
        ready = 'Virtual Mac: running, desktop ready\nAgent in the virtual Mac: 0.9.11 (43)\n'
        with patch.object(module, 'cli', side_effect=[mismatch, ready]) as cli, \
                patch.object(module.time, 'sleep') as sleep:
            self.assertEqual(module.wait_ready('/test/chatcomputer'), '0.9.11 (43)')
        self.assertEqual(cli.call_count, 2)
        sleep.assert_called_once_with(2)

    def test_version_mismatch_times_out_without_starting_a_model_task(self):
        mismatch = ('Virtual Mac: running, desktop ready\n'
                    'Agent in the virtual Mac: 0.9.12 (73) (this app brings 0.9.11 (43))\n')
        with patch.object(module, 'cli', return_value=mismatch), \
                patch.object(module.time, 'time', side_effect=[0, 0, 181]), \
                patch.object(module.time, 'sleep'), patch.object(module, 'stage_attachments') as stage, \
                patch.object(module, 'run_codex') as model:
            with self.assertRaisesRegex(RuntimeError, 'bundled guest agent'):
                module.run_task({'id': 'unstarted'}, 1, '/test/chatcomputer', agent_name='codex')
        stage.assert_not_called()
        model.assert_not_called()

    def test_failed_restore_preserves_the_before_regression_snapshot(self):
        with patch.object(module.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'restore failed')) as run:
            with self.assertRaisesRegex(RuntimeError, 'restore failed'):
                module.restore_before_regression('/test/chatcomputer')
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0][1:3], ['snapshot', 'restore'])

    def test_snapshot_is_deleted_only_after_a_successful_restore(self):
        with patch.object(module.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'ok', '')) as run, \
                patch.object(module, 'wait_ready', return_value='0.9.11 (43)') as ready:
            module.restore_before_regression('/test/chatcomputer')
        self.assertEqual([c.args[0][1:3] for c in run.call_args_list],
                         [['snapshot', 'restore'], ['snapshot', 'delete']])
        ready.assert_called_once_with('/test/chatcomputer')

    def test_restore_response_without_guest_readiness_keeps_the_backup(self):
        with patch.object(module, 'cli', return_value='restored') as cli, \
                patch.object(module, 'wait_ready', side_effect=RuntimeError('guest did not restart')):
            with self.assertRaisesRegex(RuntimeError, 'guest did not restart'):
                module.restore_before_regression('/test/chatcomputer')
        cli.assert_called_once_with(['snapshot', 'restore', 'Before regression', '--no-save'], '/test/chatcomputer')

    def test_failed_cleanup_cannot_hide_behind_successful_tasks(self):
        result = {'task': 'textedit-note', 'passed': True, 'seconds': 1,
                  'turns': 1, 'costUSD': 0, 'detail': 'ok'}
        def process(args, **kwargs):
            failed = args[1:3] == ['snapshot', 'restore']
            return subprocess.CompletedProcess(args, 1 if failed else 0, '', 'restore failed' if failed else '')
        with patch('sys.argv', ['external.py', '--only', 'textedit-note']), \
                patch.object(module, 'wait_ready'), patch.object(module, 'run_task', return_value=result), \
                patch.object(module.subprocess, 'run', side_effect=process) as run, patch('builtins.print'):
            with self.assertRaisesRegex(RuntimeError, 'restore failed'):
                module.main()
        self.assertFalse(any(c.args[0][1:3] == ['snapshot', 'delete'] for c in run.call_args_list))

    def test_failed_snapshot_deletion_is_reported(self):
        with patch.object(module.subprocess, 'run', side_effect=[
                subprocess.CompletedProcess([], 0, 'restored', ''),
                subprocess.CompletedProcess([], 1, '', 'delete failed')]), \
                patch.object(module, 'wait_ready', return_value='0.9.11 (43)'):
            with self.assertRaisesRegex(RuntimeError, 'delete failed'):
                module.restore_before_regression('/test/chatcomputer')

    def result(self, process):
        task = {'id': 'test', 'goal': 'read a label',
                'checks': [{'type': 'answer', 'contains': ['expected answer']}]}
        with tempfile.TemporaryDirectory() as tmp, \
                patch.object(module, 'OUTBOX', Path(tmp) / 'outbox'), \
                patch.object(module, 'INBOX', Path(tmp) / 'inbox'), \
                patch.object(module, 'cli'), patch.object(module, 'wait_ready'), \
                patch.object(module.subprocess, 'run', side_effect=process if isinstance(process, Exception) else None,
                             return_value=process):
            return module.run_task(task, 1, '/test/chatcomputer')

    def test_nonzero_exit_cannot_pass_with_a_correct_partial_answer(self):
        result = self.result(subprocess.CompletedProcess([], 1, json.dumps({'result': 'expected answer'})))
        self.assertFalse(result['passed'])
        self.assertIn('status 1', result['detail'])

    def test_reported_error_cannot_pass_with_a_correct_answer(self):
        result = self.result(subprocess.CompletedProcess([], 0, json.dumps({'result': 'expected answer', 'is_error': True})))
        self.assertFalse(result['passed'])

    def test_timeout_cannot_pass_with_a_correct_partial_answer(self):
        result = self.result(subprocess.TimeoutExpired([], 900, output=json.dumps({'result': 'expected answer'}).encode()))
        self.assertFalse(result['passed'])
        self.assertIn('timed out', result['detail'])

    def test_success_still_checks_the_answer(self):
        self.assertTrue(self.result(subprocess.CompletedProcess([], 0, json.dumps({'result': 'expected answer'})))['passed'])
        self.assertFalse(self.result(subprocess.CompletedProcess([], 0, json.dumps({'result': 'wrong'})))['passed'])

    def test_unknown_task_selection_cannot_report_zero_of_zero_success(self):
        result = subprocess.run(['python3', str(SCRIPT), '--only', 'no-such-task'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('unknown task IDs', result.stderr)

    def test_zero_runs_cannot_report_success(self):
        result = subprocess.run(['python3', str(SCRIPT), '--runs', '0'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)


if __name__ == '__main__': unittest.main()
