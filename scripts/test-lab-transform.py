#!/usr/bin/env python3
"""Qualify the private Lab preview primitive without an engine or GUI."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sanitize', action='store_true')
    parser.add_argument('--deps', type=Path, default=ROOT / '_deps/macports')
    args = parser.parse_args()
    deps = args.deps.resolve(strict=True)
    env = os.environ.copy()
    env['PKG_CONFIG_LIBDIR'] = f'{deps}/lib/pkgconfig:{deps}/share/pkgconfig'
    env['PKG_CONFIG_PATH'] = ''
    flags = shlex.split(subprocess.check_output(
        [str(deps / 'bin/pkg-config'), '--cflags', '--libs', 'lcms2'],
        env=env, text=True, timeout=30))
    with tempfile.TemporaryDirectory(prefix='glims-lab-transform-') as folder:
        work = Path(folder)
        for key, child in [('HOME', 'home'), ('CFFIXED_USER_HOME', 'home'),
                           ('XDG_CACHE_HOME', 'cache'), ('XDG_CONFIG_HOME', 'config'),
                           ('XDG_DATA_HOME', 'data'), ('TMPDIR', 'tmp')]:
            (work / child).mkdir(exist_ok=True)
            env[key] = str(work / child)
        compiler = ['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O2']
        if args.sanitize:
            compiler += ['-O1', '-g', '-fsanitize=address,undefined', '-fno-sanitize-recover=all']
        command = compiler + ['-I', str(ROOT / 'Engine'),
            str(ROOT / 'Engine/lab-transform.c'), str(ROOT / 'Engine/tests/lab-transform-tests.c'),
            *flags, '-o', str(work / 'tests')]
        print(shlex.join(command), flush=True)
        subprocess.run(command, env=env, check=True, timeout=120)
        return subprocess.run([str(work / 'tests')], env=env, timeout=60).returncode


if __name__ == '__main__':
    raise SystemExit(main())
