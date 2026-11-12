#!/usr/bin/env python3
"""Measure Multichannel viewport latency through a built adapter's public API.

The adapter is read only. Documents, settings and caches stay in --work, or in
an automatically removed temporary directory. Timings are JSON lines in run.log;
no hardware-independent pass threshold is imposed.
"""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(library: Path, work: Path, timeout: float) -> int:
    work.mkdir(parents=True, exist_ok=True)
    binary = work / 'component-perf'
    with (work / 'build.log').open('w') as log:
        subprocess.run(['xcrun', 'clang', '-O2', '-std=c11', '-Wall', '-Wextra', '-Werror',
                        '-I', str(ROOT / 'Sources/CGlimsEngine/include'),
                        str(ROOT / 'Engine/tests/component-perf.c'), '-o', str(binary)],
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    env = os.environ.copy()
    for key, leaf in [('HOME', 'home'), ('CFFIXED_USER_HOME', 'home'),
                      ('XDG_CACHE_HOME', 'cache'), ('XDG_CONFIG_HOME', 'config'),
                      ('XDG_DATA_HOME', 'data'), ('GIMP3_DIRECTORY', 'user'), ('TMPDIR', 'tmp')]:
        (work / leaf).mkdir(exist_ok=True)
        env[key] = str(work / leaf)
    with (work / 'run.log').open('w') as log:
        process = subprocess.Popen([str(binary), str(library), str(work)], env=env,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
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
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--work', type=Path)
    parser.add_argument('--timeout', type=float, default=240)
    args = parser.parse_args()
    if not args.library.is_file():
        parser.error('--library must name a built engine adapter')
    if not 0 < args.timeout <= 3600:
        parser.error('--timeout must be within 0–3600 seconds')
    if args.work:
        return run(args.library.resolve(), args.work.resolve(), args.timeout)
    with tempfile.TemporaryDirectory(prefix='glims-component-perf-') as work:
        return run(args.library.resolve(), Path(work), args.timeout)


if __name__ == '__main__':
    raise SystemExit(main())
