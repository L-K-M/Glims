#!/usr/bin/env python3
"""Check optional helper timeout, termination and reaping without starting GIMP."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    prefix = ROOT / '_deps/macports'
    environment = dict(os.environ, PKG_CONFIG_LIBDIR=str(prefix / 'lib/pkgconfig'))
    flags = shlex.split(subprocess.check_output(
        [str(prefix / 'bin/pkg-config'), '--cflags', '--libs', 'gio-2.0'],
        env=environment, text=True))
    with tempfile.TemporaryDirectory(prefix='glims-startup-helper-test-') as temporary:
        work = Path(temporary)
        binary = work / 'startup-helper-tests'
        subprocess.run(['xcrun', 'clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                        '-mmacosx-version-min=13.0', '-I', str(ROOT / 'Engine'),
                        str(ROOT / 'Engine/startup-helper.c'),
                        str(ROOT / 'Engine/tests/startup-helper-tests.c'), *flags,
                        '-o', str(binary)], check=True)
        subprocess.run([str(binary), str(work)], cwd=work, check=True, timeout=15)


if __name__ == '__main__':
    main()
