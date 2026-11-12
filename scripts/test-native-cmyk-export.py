#!/usr/bin/env python3
"""Run native CMYK PSD export regression tests against a matching adapter build.

The producer adapter is read only; build it with scripts/build-adapter.sh first.
All test files, caches and engine state live under --work (retained for
diagnosis), or in an automatically removed temporary directory.
"""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(producer: Path, profile: Path, work: Path, timeout: float) -> int:
    work = work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    for leaf in ('home', 'cache', 'config', 'data', 'user', 'tmp'):
        (work / leaf).mkdir(exist_ok=True)

    for name in ('compile.rsp', 'objects.rsp', 'link.rsp'):
        if not (producer / name).is_file():
            raise SystemExit(f'Matching adapter producer is missing {name}: {producer}')

    native_obj = producer / 'obj' / 'native-cmyk-export.o'
    if not native_obj.is_file():
        raise SystemExit(
            f'Matching adapter producer is missing obj/native-cmyk-export.o: {producer} '
            '(refusing stale producer without native CMYK exporter)'
        )

    obj = work / 'native-cmyk-export-tests.o'
    binary = work / 'native-cmyk-export-tests'
    with (work / 'build.log').open('w') as log:
        subprocess.run(
            ['xcrun', 'clang', '@' + str(producer / 'compile.rsp'),
             '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror=implicit-function-declaration',
             '-I', str(ROOT / 'Engine'), '-I', str(ROOT / 'Sources/CGlimsEngine/include'),
             '-c', str(ROOT / 'Engine/tests/native-cmyk-export-tests.c'), '-o', str(obj)],
            stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
        subprocess.run(
            ['xcrun', 'clang++', '-o', str(binary), str(obj)] +
            [str(p) for p in sorted((producer / 'obj').glob('*.o'))] +
            ['@' + str(producer / 'objects.rsp'), '@' + str(producer / 'link.rsp')],
            stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)

    env = os.environ.copy()
    for key, leaf in [('HOME', 'home'), ('CFFIXED_USER_HOME', 'home'),
                      ('XDG_CACHE_HOME', 'cache'), ('XDG_CONFIG_HOME', 'config'),
                      ('XDG_DATA_HOME', 'data'), ('GIMP3_DIRECTORY', 'user'),
                      ('TMPDIR', 'tmp')]:
        env[key] = str(work / leaf)

    with (work / 'run.log').open('w') as log:
        process = subprocess.Popen(
            [str(binary), str(work), str(profile.resolve())],
            cwd=str(work), env=env, stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True)
        try:
            result = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            result = 124
    print((work / 'run.log').read_text(), end='')
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--producer', type=Path, required=True)
    parser.add_argument('--cmyk-profile', type=Path, required=True)
    parser.add_argument('--work', type=Path)
    parser.add_argument('--timeout', type=float, default=300)
    args = parser.parse_args()
    if not (0 < args.timeout <= 3600):
        parser.error('--timeout must be within 0–3600 seconds')
    if not args.cmyk_profile.is_file():
        parser.error('CMYK profile is missing')
    producer = args.producer.resolve()
    if not producer.is_dir():
        parser.error('--producer must be a directory')
    if args.work:
        return run(producer, args.cmyk_profile, args.work.resolve(), args.timeout)
    with tempfile.TemporaryDirectory(prefix='glims-cmyk-export-') as work:
        return run(producer, args.cmyk_profile, Path(work), args.timeout)


if __name__ == '__main__':
    raise SystemExit(main())
