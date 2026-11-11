#!/usr/bin/env python3
"""Compile-only native gamut-warning contract harness (test-only slice).

build --producer PREFIX --out DIRECTORY [--ref GIMP_REF] [--adapter-root DIR]
run   --binary BINARY --work DIRECTORY [--timeout SECONDS]

Only the pinned engine set GIMP_3_2_8 (the first ENGINE_SETS entry in
scripts/engine.env) is accepted: the inherited proof-render helper slice is
verified against that ref only, so any other --ref is rejected instead of
guessed. --producer defaults to ADAPTER_ROOT/REF/libglimsengine producer
prefix (ADAPTER_ROOT defaults to $GLIMS_ADAPTER_ROOT or <repo>/_engine/adapter).

build compiles the current display renderer plus the harness
Engine/tests/proof-gamut-tests.c (which includes proof-render-tests.c with a
renamed main) against an existing immutable producer prefix (compile.rsp,
objects.rsp, link.rsp and obj/*.o, including a fresh engine.o and the
display-render.o that gets replaced). It never rebuilds or overwrites the
producer or any evidence: the output directory must be new or empty and must
not overlap the producer in either direction, the producer's response/object
inputs are hashed into a manifest written inside the output directory, and
those hashes are re-verified unchanged after linking.

run is a separate explicit step: it only executes an already-built binary,
in a work directory that must be new or empty, with a fresh private
HOME/XDG/GIMP3_DIRECTORY/TMPDIR environment and G_DEBUG=fatal-criticals.

Expected on the current renderer: the candidate owned bit 2 is refused, so
the run is RED by contract until production maps it; this driver reports the
harness exit status unchanged.
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
INCLUDED = ROOT / 'Engine/tests/proof-render-tests.c'
HARNESS = ROOT / 'Engine/tests/proof-gamut-tests.c'
PINNED_REF = 'GIMP_3_2_8'


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


def pinned_ref():
    env_file = ROOT / 'scripts' / 'engine.env'
    for line in env_file.read_text().splitlines():
        if line.startswith('ENGINE_SETS='):
            value = line.split('=', 1)[1].strip().strip('"')
            return value.split()[0].split(':')[0]
    raise RuntimeError('scripts/engine.env has no ENGINE_SETS')


def resolve_ref(value):
    ref = value or pinned_ref()
    if ref != PINNED_REF:
        raise RuntimeError(
            f'ref {ref} is rejected: the inherited proof-render helper slice is '
            f'verified only on the pinned {PINNED_REF}; verify actual inherited-'
            'helper compatibility before adding support for another ref')
    return ref


def build(args):
    ref = resolve_ref(args.ref)
    if args.producer:
        producer = args.producer.resolve()
    else:
        adapter_root = Path(args.adapter_root or os.environ.get('GLIMS_ADAPTER_ROOT')
                            or (ROOT / '_engine' / 'adapter')).resolve()
        producer = adapter_root / ref
    out = args.out.resolve()
    need(producer.is_dir(), f'No existing producer: {producer}')
    need(not out.is_relative_to(producer) and not producer.is_relative_to(out),
         'Test output must not overlap the immutable producer prefix in either direction')
    rsp = [producer / name for name in ('compile.rsp', 'objects.rsp', 'link.rsp')]
    need(all(p.is_file() for p in rsp), 'Producer requires compile.rsp, objects.rsp and link.rsp')
    all_objects = sorted((producer / 'obj').glob('*.o'))
    need(any(p.name == 'engine.o' for p in all_objects), 'Authentic producer engine.o is required')
    need(any(p.stem == READER.stem for p in all_objects), 'Producer display-render.o is required for replacement')
    need(HARNESS.is_file() and INCLUDED.is_file(), 'Harness sources are missing from the checkout')
    out.mkdir(parents=True, exist_ok=True)
    need(not any(out.iterdir()), f'Output directory must be new or empty; nothing is deleted: {out}')
    objects = [p for p in all_objects if p.stem != READER.stem]
    producer_inputs = [*rsp, *all_objects]
    before = {str(p): sha(p) for p in producer_inputs}
    manifest = out / 'producer-inputs.sha256'
    with manifest.open('w') as stream:
        for path, digest in before.items():
            stream.write(f'{digest}  {path}\n')
        for repo_file in (READER, INCLUDED):
            stream.write(f'{sha(repo_file)}  {repo_file}\n')
    reader_object, harness_object = out / 'display-render.o', out / 'proof-gamut-tests.o'
    binary = out / 'proof-gamut-tests'
    # Own headers precede producer include flags. The harness includes
    # proof-render-tests.c with a renamed main, so unused-function warnings
    # from the dead included suite are suppressed; everything else is -Werror.
    common = ['-I', ROOT / 'Sources/CGlimsEngine/include', '-I', ROOT / 'Engine', f'@{rsp[0]}',
              '-Wall', '-Wextra', '-Werror=implicit-function-declaration']
    try:
        print('==> compile current display renderer (producer unchanged)', flush=True)
        invoke(['xcrun', 'clang', *common, '-fvisibility=hidden', '-c', READER, '-o', reader_object])
        print('==> compile independent native gamut contract harness', flush=True)
        invoke(['xcrun', 'clang', *common, '-std=c11', '-O2', '-Werror', '-Wno-unused-function',
                '-c', HARNESS, '-o', harness_object])
        print('==> link compile-only; no engine or test execution', flush=True)
        invoke(['xcrun', 'clang++', '-o', binary, reader_object, harness_object, *objects,
                f'@{rsp[1]}', f'@{rsp[2]}'])
    finally:
        need(all(Path(p).is_file() and sha(Path(p)) == digest for p, digest in before.items()),
             'Producer changed while compiling the isolated test; preserve outputs for inspection')
    print(f'-- built {binary}; NOT RUN; expected RED on the current renderer until bit 2 is mapped',
          flush=True)


def run(args):
    binary, work = args.binary.resolve(), args.work.resolve()
    need(binary.is_file(), f'No already-built harness: {binary}')
    need(args.timeout > 0, 'Timeout must be positive')
    work.mkdir(parents=True, exist_ok=True)
    need(not any(work.iterdir()), f'Work directory must be new or empty; no existing contents are deleted: {work}')
    env = os.environ.copy()
    for key, leaf in [('HOME', 'home'), ('XDG_CONFIG_HOME', 'config'), ('XDG_DATA_HOME', 'data'),
                      ('XDG_CACHE_HOME', 'cache'), ('XDG_STATE_HOME', 'state'),
                      ('GIMP3_DIRECTORY', 'user'), ('TMPDIR', 'tmp')]:
        directory = work / leaf
        directory.mkdir()
        env[key] = str(directory)
    env['G_DEBUG'] = 'fatal-criticals'
    command = [str(binary), str(work)]
    print('==> explicit native run with fresh private HOME/XDG/GIMP/TMP; no GUI', flush=True)
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
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
                                     epilog='example: python3 scripts/test-proof-gamut.py build '
                                            '--ref GIMP_3_2_8 --out "$PWD/.build/proof-gamut" && '
                                            'python3 scripts/test-proof-gamut.py run '
                                            '--binary "$PWD/.build/proof-gamut/proof-gamut-tests" '
                                            '--work "$PWD/.build/proof-gamut-run"')
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('build', help='Compile/link only, against an existing immutable producer')
    p.add_argument('--producer', type=Path, help='existing producer prefix (default: ADAPTER_ROOT/REF)')
    p.add_argument('--adapter-root', type=Path, help='adapter output root (default: $GLIMS_ADAPTER_ROOT or <repo>/_engine/adapter)')
    p.add_argument('--ref', help=f'engine set name; only the pinned {PINNED_REF} is accepted')
    p.add_argument('--out', type=Path, required=True, help='new or empty output directory outside the producer')
    p = commands.add_parser('run', help='Explicitly execute an already-built native harness')
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--work', type=Path, required=True, help='new or empty private work directory')
    p.add_argument('--timeout', type=int, default=180)
    args = parser.parse_args()
    try:
        if args.command == 'build':
            build(args)
            return 0
        return run(args)
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f'test-proof-gamut: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
