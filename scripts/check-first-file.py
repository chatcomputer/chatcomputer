#!/usr/bin/env python3
"""Check a fresh-install task's actual plain-text output on the host."""
from pathlib import Path
import sys


def verify(root, name, expected):
    root = Path(root).resolve(strict=True)
    if Path(name).name != name or name in ('.', '..'):
        raise ValueError('expected a plain file name')
    for path in root.rglob(name):
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root) or path.stat().st_size > 1024 * 1024:
            continue
        data = path.read_bytes()
        for encoding in ('utf-8-sig', 'utf-16'):
            try:
                if data.decode(encoding).strip() == expected:
                    return
            except UnicodeError:
                continue
    raise ValueError('no matching plain-text output with the expected content')


if __name__ == '__main__':
    try:
        verify(*sys.argv[1:])
    except (ValueError, OSError) as error:
        print('FAIL: output verification: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
    print('PASS: host verified the plain-text output')
