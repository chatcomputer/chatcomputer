import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'regress/codex_agent.py'
spec = importlib.util.spec_from_file_location('codex_agent', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def events(*extra):
    return '\n'.join(json.dumps(e) for e in [
        {'type': 'item.completed', 'item': {'type': 'agent_message', 'text': 'expected answer'}},
        *extra])


class CodexFailures(unittest.TestCase):
    def test_failed_product_path_typo_can_recover_but_a_host_command_cannot(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = str(Path(tmp) / 'Product.app/Contents/MacOS/Product')
            alias = str(Path(tmp) / 'Product')
            text = events({'type': 'item.completed', 'item': {'type': 'command_execution', 'command': alias + ' help', 'exit_code': 127}}, {'type': 'turn.completed'})
            self.assertFalse(module.parse_report(text, 'test-model', binary)['is_error'])
            text = events({'type': 'item.completed', 'item': {'type': 'command_execution', 'command': '/usr/bin/curl example.com', 'exit_code': 127}}, {'type': 'turn.completed'})
            self.assertTrue(module.parse_report(text, 'test-model', binary)['is_error'])

    def test_cli_shell_keeps_the_isolated_data_directory_after_environment_filtering(self):
        with patch.dict(os.environ, {'CC_DATA_DIR': '/private/test-vm'}):
            args = module.command('/test/chatcomputer', 'cli', 'task', 'test-model', '/scratch')
        self.assertIn('shell_environment_policy.set.CC_DATA_DIR="/private/test-vm"', args)
        self.assertIn('sandbox_workspace_write.network_access=true', args)
        self.assertNotIn('--add-dir', args)

    def test_host_file_edits_cannot_fabricate_a_successful_guest_output(self):
        text = events({'type': 'item.completed', 'item': {'type': 'file_change'}}, {'type': 'turn.completed'})
        self.assertTrue(module.parse_report(text, 'test-model')['is_error'])

    def test_host_scripting_or_command_chains_cannot_pass_as_cli_interaction(self):
        for text in ['python3 make-output.py', '/test/chatcomputer status; touch /host/outbox/note.txt',
                     '/test/chatcomputer type "$(cat /host/file)"']:
            self.assertFalse(module.cli_command_only(text, '/test/chatcomputer'))
        self.assertTrue(module.cli_command_only('/bin/zsh -c \'/test/chatcomputer type "hello world"\'', '/test/chatcomputer'))

    def test_partial_answer_does_not_pass_without_completed_turn(self):
        self.assertTrue(module.parse_report(events(), 'test-model')['is_error'])

    def test_failed_turn_cannot_pass_with_correct_partial_answer(self):
        self.assertTrue(module.parse_report(events({'type': 'turn.failed'}), 'test-model')['is_error'])

    def test_malformed_event_after_completion_cannot_pass(self):
        text = events({'type': 'turn.completed'}) + '\nnot JSON'
        self.assertTrue(module.parse_report(text, 'test-model')['is_error'])

    def test_nonzero_exit_cannot_pass_with_completed_answer(self):
        output = events({'type': 'turn.completed'})
        with patch.object(module.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, output, 'error')):
            report, failure = module.run('/test/chatcomputer', 'cli', 'test', 'test-model')
        self.assertEqual(report['result'], 'expected answer')
        self.assertIn('status 1', failure)

    def test_timeout_cannot_pass_with_completed_answer(self):
        with patch.object(module.subprocess, 'run', side_effect=subprocess.TimeoutExpired([], 900, output=events({'type': 'turn.completed'}).encode())):
            _, failure = module.run('/test/chatcomputer', 'cli', 'test', 'test-model')
        self.assertEqual(failure, 'agent timed out')

    def test_completed_usage_counts_cached_input_once(self):
        report = module.parse_report(events({'type': 'turn.completed', 'usage': {'input_tokens': 100, 'cached_input_tokens': 60, 'output_tokens': 5}}), 'test-model')
        self.assertFalse(report['is_error'])
        self.assertEqual(report['usage']['input_tokens'] + report['usage']['cache_read_input_tokens'], 100)

    def test_model_process_does_not_inherit_api_secrets_or_a_writable_vm_root(self):
        with patch.dict(os.environ, {'CC_DATA_DIR': '/private/test-vm', 'CC_API_KEY': 'fake-secret', 'ANTHROPIC_API_KEY': 'fake-secret'}), \
                patch.object(module.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, events({'type': 'turn.completed'}), '')) as run:
            module.run('/test/chatcomputer', 'mcp', 'test', 'test-model')
        call = run.call_args
        self.assertNotIn('CC_API_KEY', call.kwargs['env'])
        self.assertNotIn('ANTHROPIC_API_KEY', call.kwargs['env'])
        self.assertNotIn('--add-dir', call.args[0])
        self.assertIn('features.shell_tool=false', call.args[0])
        self.assertIn('agents.enabled=false', call.args[0])


if __name__ == '__main__':
    unittest.main()
