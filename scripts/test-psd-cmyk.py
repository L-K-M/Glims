#!/usr/bin/env python3
"""Run CMYK PSD conformance against an explicit external CMYK ICC profile.

The profile is read in place and never copied into the repository. Compile
against the public facade and LittleCMS (independent color-conversion oracle).
All native settings, caches and temporary files use an isolated directory.

  python3 scripts/test-psd-cmyk.py --cmyk-profile /path/to/printer.icc
      [--ref GIMP_REF] [--adapter-root DIR] [--timeout SECONDS]
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
TEST_SOURCE = ROOT / 'Engine' / 'tests' / 'psd-cmyk-tests.c'


def pinned_ref() -> str:
    """The first GIMP_REF in ENGINE_SETS of scripts/engine.env."""
    text = (ROOT / 'scripts' / 'engine.env').read_text(encoding='utf-8')
    match = re.search(r'^ENGINE_SETS="([^:\s"]+)', text, re.MULTILINE)
    if not match:
        raise SystemExit('could not parse ENGINE_SETS from scripts/engine.env')
    return match.group(1)


def main() -> int:
    parser = argparse.ArgumentParser(
        description='Build and run the CMYK PSD export conformance tests.')
    parser.add_argument('--ref', default=pinned_ref(),
                        help='engine set name (default: pinned set from scripts/engine.env: %(default)s)')
    parser.add_argument('--adapter-root', default=os.environ.get(
                            'GLIMS_ADAPTER_ROOT', str(ROOT / '_engine' / 'adapter')),
                        help='directory holding <ref>/libglimsengine.dylib '
                             '(default: $GLIMS_ADAPTER_ROOT or <repo>/_engine/adapter)')
    parser.add_argument('--timeout', type=float, default=600.0,
                        help='seconds the test runner may take (default: %(default)s)')
    parser.add_argument('--cmyk-profile', type=Path, required=True,
                        help='external CMYK output ICC profile; never copied into the repository')
    args = parser.parse_args()
    profile = args.cmyk_profile.resolve()
    if not profile.is_file():
        raise SystemExit(f'CMYK profile not found: {profile}')

    adapter = Path(args.adapter_root).resolve() / args.ref / 'libglimsengine.dylib'
    if not adapter.is_file():
        raise SystemExit(f'adapter library not found: {adapter} '
                         f'(build it with scripts/build-adapter.sh {args.ref})')

    with tempfile.TemporaryDirectory(prefix='glims-psd-cmyk-') as tmp:
        work = Path(tmp)
        for child in ('home', 'cache', 'gimp', 'user', 'config', 'data', 'tmp'):
            (work / child).mkdir()

        runner = work / 'glims-psd-cmyk-tests'

        compile_cmd = ['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                       '-I', str(FACADE_INCLUDE), '-I', str(ROOT / '_deps/macports/include'),
                       str(TEST_SOURCE), str(ROOT / '_deps/macports/lib/liblcms2.dylib'), '-o', str(runner)]
        print('+', ' '.join(compile_cmd), flush=True)
        subprocess.run(compile_cmd, check=True)

        env = os.environ.copy()
        env.update(HOME=str(work / 'home'),
                   XDG_CACHE_HOME=str(work / 'cache'),
                   GIMP3_DIRECTORY=str(work / 'gimp'), CFFIXED_USER_HOME=str(work / 'home'),
                   XDG_CONFIG_HOME=str(work / 'config'), XDG_DATA_HOME=str(work / 'data'), TMPDIR=str(work / 'tmp'))
        run_cmd = [str(runner), str(adapter), str(work), str(profile)]
        print('+', ' '.join(run_cmd), flush=True)
        try:
            result = subprocess.run(run_cmd, env=env, timeout=args.timeout)
        except subprocess.TimeoutExpired:
            print(f'test runner did not finish within {args.timeout:g} s', file=sys.stderr)
            return 124
        return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
