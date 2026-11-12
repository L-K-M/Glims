#!/usr/bin/env python3
"""Run independent linear-sRGB -> D50 Lab checks without a GIMP producer or GUI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def qualify(args, work):
    deps = args.deps.resolve(strict=True)
    env = os.environ.copy()
    env['PKG_CONFIG_LIBDIR'] = f'{deps}/lib/pkgconfig:{deps}/share/pkgconfig'
    env['PKG_CONFIG_PATH'] = ''
    for key, leaf in [('HOME', 'home'), ('CFFIXED_USER_HOME', 'home'),
                      ('XDG_CACHE_HOME', 'cache'), ('XDG_CONFIG_HOME', 'config'),
                      ('XDG_DATA_HOME', 'data'), ('TMPDIR', 'tmp')]:
        (work / leaf).mkdir(exist_ok=True)
        env[key] = str(work / leaf)
    flags = shlex.split(subprocess.check_output(
        [str(deps / 'bin/pkg-config'), '--cflags', '--libs', 'lcms2'],
        env=env, text=True, timeout=30))
    inputs = [ROOT / 'Engine/lab-transform.c', ROOT / 'Engine/lab-transform.h',
              ROOT / 'Engine/tests/lab-rgb-transform-tests.c', Path(__file__).resolve()]
    hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    (work / 'inputs.json').write_text(json.dumps(hashes, indent=2))
    compiler = ['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-pedantic',
                '-O1' if args.sanitize else '-O2']
    if args.sanitize:
        compiler += ['-g', '-fsanitize=address,undefined', '-fno-sanitize-recover=all']
    command = compiler + ['-I', str(ROOT / 'Engine'), str(inputs[0]), str(inputs[2]),
                           *flags, '-lm', '-o', str(work / 'tests')]
    (work / 'command.json').write_text(json.dumps(command, indent=2))
    print(shlex.join(command), flush=True)
    code = 1
    phase = 'build'
    try:
        with (work / 'build.log').open('x') as log:
            subprocess.run(command, cwd=work, env=env, stdin=subprocess.DEVNULL,
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
        phase = 'run'
        with (work / 'run.log').open('x') as log:
            code = subprocess.run([str(work / 'tests')], cwd=work, env=env,
                                  stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                  timeout=60).returncode
        print((work / 'run.log').read_text(), end='', flush=True)
    finally:
        changed = [str(p) for p in inputs if hashlib.sha256(p.read_bytes()).hexdigest() != hashes[str(p)]]
        (work / 'result.json').write_text(json.dumps(dict(exit_code=code, phase=phase,
            sanitized=args.sanitize, changed_inputs=changed), indent=2))
        if changed:
            raise RuntimeError(f'Input changed during qualification: {changed}')
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sanitize', action='store_true')
    parser.add_argument('--deps', type=Path, default=ROOT / '_deps/macports')
    parser.add_argument('--work', type=Path, help='New empty output directory to retain build/run logs')
    args = parser.parse_args()
    if args.work is not None:
        work = args.work.resolve()
        work.mkdir(parents=True, exist_ok=False)
        return qualify(args, work)
    with tempfile.TemporaryDirectory(prefix='glims-lab-rgb-transform-') as folder:
        return qualify(args, Path(folder))


if __name__ == '__main__':
    raise SystemExit(main())
