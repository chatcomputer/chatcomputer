"""Codex CLI adapter for the external GUI benchmark; never writes inside the VM bundle."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile


def command(binary, via, prompt, model, work):
    args = ['codex', 'exec', '--ephemeral', '--ignore-user-config', '--ignore-rules',
            '--json', '--sandbox', 'workspace-write', '--skip-git-repo-check',
            '--cd', str(work), '--model', model]
    settings = {'approval_policy': 'never', 'agents.enabled': False,
                'web_search': 'disabled', 'features.shell_snapshot': False,
                'allow_login_shell': False, 'features.view_image': via == 'cli'}
    # Codex filters the environment again for its shell tools. Forward the isolated
    # data directory explicitly at that boundary as well as to the Codex process.
    settings['shell_environment_policy.set.CHATCOMPUTER_CLIENT'] = 'Regression'
    if os.environ.get('CC_DATA_DIR'):
        settings['shell_environment_policy.set.CC_DATA_DIR'] = os.environ['CC_DATA_DIR']
        if via == 'cli':
            # The product CLI connects over a Unix socket. Keep filesystem writes
            # inside the temporary workspace; audit every command against the CLI.
            settings['sandbox_workspace_write.network_access'] = True
    if via == 'mcp':
        settings.update({'features.shell_tool': False,
                         'mcp_servers.chatcomputer.command': binary,
                         'mcp_servers.chatcomputer.args': ['mcp'],
                         'mcp_servers.chatcomputer.env.CHATCOMPUTER_CLIENT': 'Regression',
                         'mcp_servers.chatcomputer.default_tools_approval_mode': 'approve',
                         'mcp_servers.chatcomputer.tool_timeout_sec': 180})
        if os.environ.get('CC_DATA_DIR'):
            settings['mcp_servers.chatcomputer.env.CC_DATA_DIR'] = os.environ['CC_DATA_DIR']
    for key, value in settings.items():
        args += ['-c', key + '=' + json.dumps(value)]
    return [*args, prompt]


def cli_command_only(command_text, binary):
    """Audit the benchmark boundary; host scripting cannot stand in for guest interaction."""
    try:
        words = shlex.split(command_text)
        if words and Path(words[0]).name in ('sh', 'bash', 'zsh'):
            if len(words) != 3 or words[1] not in ('-c', '-lc'):
                return False
            command_text = words[2]
        lexer = shlex.shlex(command_text, posix=True, punctuation_chars=';&|<>')
        lexer.whitespace_split = True
        words = list(lexer)
        return bool(words) and words[0] == binary and not any(
            word in (';', '&&', '||', '|', '&', '>', '>>', '<', '<<') or '$(' in word or '`' in word
            for word in words)
    except ValueError:
        return False


def parse_report(stdout, model, binary=None, via='cli'):
    """A correct partial answer is insufficient without a completed, error-free turn."""
    answer, usage, errors, completed, turns = [], {}, [], False, 0
    for line in stdout.splitlines():
        if not line.strip():
            continue
        try:
            event = json.loads(line)
            if not isinstance(event, dict):
                raise ValueError('event is not an object')
        except (ValueError, TypeError):
            errors.append('invalid Codex event')
            continue
        kind = event.get('type')
        if kind in ('error', 'turn.failed'):
            errors.append(kind)
        elif kind == 'turn.completed':
            completed = True
            turns += 1
            usage = event.get('usage') or {}
        elif kind == 'item.completed':
            item = event.get('item') or {}
            if item.get('type') == 'agent_message':
                answer.append(item.get('text') or '')
            if item.get('type') == 'error':
                errors.append('error item')
            if item.get('type') == 'file_change':
                errors.append('host file editing is outside the GUI benchmark')
            if item.get('type') == 'command_execution' and binary:
                if via != 'cli' or not cli_command_only(item.get('command', ''), binary):
                    # A mistyped sibling executable that the shell could not
                    # start performed no host operation; the model may recover.
                    alias = str(Path(binary).parents[3] / Path(binary).name) if len(Path(binary).parents) > 3 else None
                    missing_alias = (alias is not None and via == 'cli' and item.get('exit_code') == 127
                                     and not Path(alias).exists()
                                     and cli_command_only(item.get('command', ''), alias))
                    if not missing_alias:
                        errors.append('host command is outside the product CLI benchmark')
            if item.get('type') == 'mcp_tool_call' and item.get('server') != 'chatcomputer':
                errors.append('unexpected MCP server')
    if not completed:
        errors.append('no completed Codex turn')
    return {'result': '\n'.join(answer), 'is_error': bool(errors),
            'errors': errors, 'num_turns': turns, 'modelUsage': {model: {}},
            'usage': {'input_tokens': usage.get('input_tokens', 0) - usage.get('cached_input_tokens', 0),
                      'cache_read_input_tokens': usage.get('cached_input_tokens', 0),
                      'output_tokens': usage.get('output_tokens', 0)}}


def run(binary, via, prompt, model, trace_prefix=None):
    # The model can write screenshots and scratch files here, but cannot directly write the host outbox.
    with tempfile.TemporaryDirectory(prefix='chatcomputer-codex-regress-') as work:
        env = {key: value for key, value in os.environ.items()
               if key in ('PATH', 'HOME', 'TMPDIR', 'CODEX_HOME', 'LANG', 'LC_ALL', 'CC_DATA_DIR')}
        env['CHATCOMPUTER_CLIENT'] = 'Regression'
        cmd = command(binary, via, prompt, model, work)
        failure = None
        try:
            process = subprocess.run(cmd, capture_output=True, text=True, timeout=900,
                                     stdin=subprocess.DEVNULL, env=env)
            stdout, stderr = process.stdout, process.stderr
            if process.returncode != 0:
                failure = f'agent exited with status {process.returncode}'
        except subprocess.TimeoutExpired as expired:
            stdout = expired.stdout or ''
            stderr = expired.stderr or ''
            stdout = stdout.decode() if isinstance(stdout, bytes) else stdout
            stderr = stderr.decode() if isinstance(stderr, bytes) else stderr
            failure = 'agent timed out'
        if trace_prefix:
            for suffix, content in [('.agent.jsonl', stdout), ('.agent.stderr', stderr)]:
                path = Path(str(trace_prefix) + suffix)
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open('x') as handle:
                    path.chmod(0o600)
                    handle.write(content)
        report = parse_report(stdout, model, binary, via)
        report['externalConfiguration'] = {'model': model, 'via': via, 'sandbox': 'workspace-write',
            'ignoreUserConfig': True, 'ephemeral': True, 'agentsEnabled': False,
            'shellTool': via == 'cli', 'commandNetworkAccess': via == 'cli',
            'writableVMRoot': False, 'apiKeyEnvironmentInherited': False}
        if report['errors'] and not failure:
            failure = '; '.join(report['errors'])
        return report, failure
