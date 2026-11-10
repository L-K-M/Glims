#!/usr/bin/env python3
"""Compile-only native proof harness against an immutable fresh API164 producer.

build --producer PREFIX --out DIRECTORY compiles display-render.c and the
native harness, then links authentic producer obj/ plus objects.rsp/link.rsp.
It excludes the producer display-render.o and never rebuilds the producer.
run is a separate explicit command with a fresh private environment. Optional
--cmyk-profile reads an external profile in place; it never copies that file.
"""
from __future__ import annotations
import argparse
import hashlib
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
READER = ROOT / 'Engine/display-render.c'
HARNESS = ROOT / 'Engine/tests/proof-render-tests.c'


def need(ok, message):
    if not ok:
        raise RuntimeError(message)


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1048576), b''):
            digest.update(chunk)
    return digest.hexdigest()


def invoke(command):
    print('    ' + shlex.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True)


def build(args):
    producer, out = args.producer.resolve(), args.out.resolve()
    need(producer.is_dir(), f'No existing producer: {producer}')
    need(not out.is_relative_to(producer), 'Test output must be outside the immutable producer prefix')
    rsp = [producer / name for name in ('compile.rsp', 'objects.rsp', 'link.rsp')]
    need(all(p.is_file() for p in rsp), 'Producer requires compile.rsp, objects.rsp and link.rsp')
    all_objects = sorted((producer / 'obj').glob('*.o'))
    need(any(p.name == 'engine.o' for p in all_objects), 'Authentic producer engine.o is required')
    need(any(p.stem == READER.stem for p in all_objects), 'Producer display-render.o is required for replacement')
    objects = [p for p in all_objects if p.stem != READER.stem]
    before = {str(p): sha(p) for p in [*rsp, *all_objects]}
    out.mkdir(parents=True, exist_ok=True)
    reader_object, harness_object = out / 'display-render.o', out / 'proof-render-tests.o'
    binary = out / 'proof-render-tests'
    # Own headers precede producer include flags. Runtime still refuses an
    # API163 engine.o: a fresh API164 producer is an explicit prerequisite.
    common = ['-I', ROOT / 'Sources/CGlimsEngine/include', '-I', ROOT / 'Engine', f'@{rsp[0]}',
              '-Wall', '-Wextra', '-Werror=implicit-function-declaration']
    try:
        print('==> compile current display renderer (producer unchanged)', flush=True)
        invoke(['xcrun', 'clang', *common, '-fvisibility=hidden', '-c', READER, '-o', reader_object])
        print('==> compile independent native proof harness', flush=True)
        invoke(['xcrun', 'clang', *common, '-std=c11', '-O2', '-Werror', '-c', HARNESS, '-o', harness_object])
        print('==> link compile-only; no engine or test execution', flush=True)
        invoke(['xcrun', 'clang++', '-o', binary, reader_object, harness_object, *objects,
                f'@{rsp[1]}', f'@{rsp[2]}'])
    finally:
        need(all(Path(p).is_file() and sha(Path(p)) == digest for p, digest in before.items()),
             'Producer changed while compiling the isolated test; preserve outputs for inspection')
    print(f'-- built {binary}; NOT RUN; requires fresh API164 engine object', flush=True)


def run(args):
    binary, work = args.binary.resolve(), args.work.resolve()
    need(binary.is_file(), f'No already-built harness: {binary}')
    need(args.timeout > 0, 'Timeout must be positive')
    profile = args.cmyk_profile.resolve() if args.cmyk_profile else None
    need(profile is None or profile.is_file(), f'No external CMYK profile: {profile}')
    work.mkdir(parents=True, exist_ok=True)
    need(not any(work.iterdir()), f'Work directory must be empty; no existing contents are deleted: {work}')
    env = os.environ.copy()
    for key, leaf in [('HOME', 'home'), ('XDG_CONFIG_HOME', 'config'), ('XDG_DATA_HOME', 'data'),
                      ('XDG_CACHE_HOME', 'cache'), ('XDG_STATE_HOME', 'state'),
                      ('GIMP3_DIRECTORY', 'user'), ('TMPDIR', 'tmp')]:
        directory = work / leaf
        directory.mkdir()
        env[key] = str(directory)
    env['G_DEBUG'] = 'fatal-criticals'
    command = [str(binary), str(work), *([str(profile)] if profile else [])]
    print('==> explicit native run with fresh HOME/XDG/GIMP/TMP; no GUI', flush=True)
    print('    ' + shlex.join(command), flush=True)
    child = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL, start_new_session=True)
    def interrupted(signum, frame):
        raise InterruptedError(f'Interrupted by signal {signum}')
    previous_term = signal.signal(signal.SIGTERM, interrupted)
    try:
        return child.wait(timeout=args.timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt, InterruptedError):
        if child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait()
        print('Native harness timed out/interrupted; private work preserved', file=sys.stderr)
        return 124
    finally:
        signal.signal(signal.SIGTERM, previous_term)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('build', help='Compile/link only, against an existing fresh API164 producer')
    p.add_argument('--producer', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p = commands.add_parser('run', help='Explicitly execute an already-built native harness')
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--work', type=Path, required=True)
    p.add_argument('--cmyk-profile', type=Path)
    p.add_argument('--timeout', type=int, default=180)
    args = parser.parse_args()
    try:
        if args.command == 'build':
            build(args)
            return 0
        return run(args)
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f'test-proof-render: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
