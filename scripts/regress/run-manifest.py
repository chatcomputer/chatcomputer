#!/usr/bin/env python3
"""Write provenance next to a regression JSONL, without reading credential files.

scripts/regress/run-manifest.py --app APP --vm-bundle VM --suite short \
    --model MODEL --results results.jsonl
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def command(*args):
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def bundle_info(app):
    if not app:
        return None
    path = Path(app)
    with (path / 'Contents/Info.plist').open('rb') as source:
        info = plistlib.load(source)
    executable = path / 'Contents/MacOS' / info['CFBundleExecutable']
    signing = subprocess.run(['codesign', '-d', '--verbose=4', str(path)], capture_output=True, text=True)
    identity = [line for line in signing.stderr.splitlines()
                if line.startswith(('Identifier=', 'TeamIdentifier=', 'Authority='))]
    return {'version': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion'),
            'bundleID': info.get('CFBundleIdentifier'), 'identity': identity,
            'executableSHA256': hashlib.sha256(executable.read_bytes()).hexdigest()}


def source_fingerprint():
    tracked_and_new = subprocess.check_output(['git', 'ls-files', '-co', '--exclude-standard', '-z'], cwd=ROOT)
    digest = hashlib.sha256()
    for name in sorted(set(tracked_and_new.split(b'\0')) - {b''}):
        # Hash build inputs and test tooling, not local data or generated results.
        if not (name.startswith((b'Apps/', b'Packages/', b'scripts/')) or name == b'project.yml'):
            continue
        if name.startswith(b'scripts/regress/results/') or Path(name.decode()).name in ('credentials.json', 'secrets.json'):
            continue
        path = ROOT / name.decode()
        if path.is_file():
            digest.update(name + b'\0' + hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True)
    parser.add_argument('--vm-bundle')
    parser.add_argument('--suite', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--results', required=True)
    parser.add_argument('--snapshot-id')
    parser.add_argument('--external-agent', choices=['claude', 'codex'], default='claude')
    args = parser.parse_args()
    app = Path(args.app).resolve()
    spec = None
    if args.vm_bundle:
        with (Path(args.vm_bundle) / 'spec.json').open() as source:
            raw = json.load(source)
        spec = {key: raw.get(key) for key in ['id', 'stage', 'restoreImageBuild', 'guestRelease',
                                             'cpuCount', 'memoryBytes', 'displayWidth', 'displayHeight']}
    tasks = Path(__file__).with_name('tasks-long.json' if args.suite == 'long' else 'tasks.json')
    manifest = {
        'recordedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'host': {'version': command('sw_vers', '-productVersion'), 'build': command('sw_vers', '-buildVersion'),
                 'hardware': command('sysctl', '-n', 'hw.model')},
        'gitCommit': command('git', 'rev-parse', 'HEAD'), 'sourceSHA256': source_fingerprint(),
        'workingTreeDirty': bool(command('git', 'status', '--porcelain')),
        'app': bundle_info(app),
        'bundledGuestAgent': bundle_info(app / 'Contents/Resources/GuestAgent/ChatComputerAgent.app'),
        'vm': spec, 'snapshotID': args.snapshot_id,
        'suite': args.suite, 'model': args.model, 'results': Path(args.results).name,
        'tasksSHA256': hashlib.sha256(tasks.read_bytes()).hexdigest(),
        'externalRunnerSHA256': hashlib.sha256(Path(__file__).with_name('external.py').read_bytes()).hexdigest(),
        'guestReadinessParserSHA256': hashlib.sha256(Path(__file__).with_name('guest_readiness.py').read_bytes()).hexdigest(),
        'externalAgent': args.external_agent,
        'externalAgentVersion': command(args.external_agent, '--version'),
        'codexAdapterSHA256': hashlib.sha256(Path(__file__).with_name('codex_agent.py').read_bytes()).hexdigest()
                             if args.external_agent == 'codex' else None,
    }
    out = Path(args.results).with_suffix('.manifest.json')
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    print(out)


if __name__ == '__main__':
    main()
