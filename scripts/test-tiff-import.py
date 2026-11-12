#!/usr/bin/env python3
"""Build and run the TIFF thumbnail import conformance tests.

Compiles Engine/tests/tiff-import-native-tests.c against the public facade
header (the runner dlopen()s the existing adapter and links libtiff only to
write independent fixtures; no GIMP headers or DYLD shim are used), then runs it with an isolated temporary HOME,
GIMP3_DIRECTORY, XDG_CACHE_HOME and engine user/cache directories.

  python3 scripts/test-tiff-import.py [--ref GIMP_REF]
      [--adapter-root DIR] [--timeout SECONDS]

--ref defaults to the pinned engine set in scripts/engine.env;
--adapter-root defaults to $GLIMS_ADAPTER_ROOT or <repo>/_engine/adapter and
must hold <ref>/libglimsengine.dylib (see scripts/build-adapter.sh).
Exits with the runner's status, or 124 on timeout.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
FACADE_INCLUDE = ROOT / 'Sources' / 'CGlimsEngine' / 'include'
TEST_SOURCE = ROOT / 'Engine' / 'tests' / 'tiff-import-native-tests.c'


def pinned_ref() -> str:
    """The first GIMP_REF in ENGINE_SETS of scripts/engine.env."""
    text = (ROOT / 'scripts' / 'engine.env').read_text(encoding='utf-8')
    match = re.search(r'^ENGINE_SETS="([^:\s"]+)', text, re.MULTILINE)
    if not match:
        raise SystemExit('could not parse ENGINE_SETS from scripts/engine.env')
    return match.group(1)


def main() -> int:
    parser = argparse.ArgumentParser(
        description='Build and run the TIFF thumbnail import conformance tests.')
    parser.add_argument('--ref', default=pinned_ref(),
                        help='engine set name (default: pinned set from scripts/engine.env: %(default)s)')
    parser.add_argument('--adapter-root', default=os.environ.get(
                            'GLIMS_ADAPTER_ROOT', str(ROOT / '_engine' / 'adapter')),
                        help='directory holding <ref>/libglimsengine.dylib '
                             '(default: $GLIMS_ADAPTER_ROOT or <repo>/_engine/adapter)')
    parser.add_argument('--timeout', type=float, default=600.0,
                        help='seconds the test runner may take (default: %(default)s)')
    args = parser.parse_args()

    adapter = Path(args.adapter_root).resolve() / args.ref / 'libglimsengine.dylib'
    if not adapter.is_file():
        raise SystemExit(f'adapter library not found: {adapter} '
                         f'(build it with scripts/build-adapter.sh {args.ref})')

    with tempfile.TemporaryDirectory(prefix='glims-tiff-import-') as tmp:
        work = Path(tmp)
        for child in ('home', 'cache', 'gimp', 'user', 'config', 'data', 'tmp'):
            (work / child).mkdir()

        runner = work / 'glims-tiff-import-tests'

        compile_cmd = ['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                       '-I', str(FACADE_INCLUDE), '-I', str(ROOT / '_deps/macports/include'),
                       str(TEST_SOURCE), str(ROOT / '_deps/macports/lib/libtiff.dylib'), '-o', str(runner)]
        print('+', ' '.join(compile_cmd), flush=True)
        subprocess.run(compile_cmd, check=True)

        env = os.environ.copy()
        env.update(HOME=str(work / 'home'),
                   XDG_CACHE_HOME=str(work / 'cache'),
                   GIMP3_DIRECTORY=str(work / 'gimp'),
                   XDG_CONFIG_HOME=str(work / 'config'), XDG_DATA_HOME=str(work / 'data'),
                   CFFIXED_USER_HOME=str(work / 'home'), TMPDIR=str(work / 'tmp'))
        run_cmd = [str(runner), str(adapter), str(work)]
        print('+', ' '.join(run_cmd), flush=True)
        try:
            result = subprocess.run(run_cmd, env=env, timeout=args.timeout)
        except subprocess.TimeoutExpired:
            print(f'test runner did not finish within {args.timeout:g} s', file=sys.stderr)
            return 124
        return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
