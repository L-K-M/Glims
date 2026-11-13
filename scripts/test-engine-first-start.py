#!/usr/bin/env python3
"""Check fresh native startup diagnostics and exact SNAP preservation.

Each input state runs in its own process and private home. The engine's
config directory deliberately does not exist when start is called.
"""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('library', type=Path)
    parser.add_argument('--output', type=Path,
                        help='new directory retaining the executable and case logs')
    args = parser.parse_args()
    library = args.library.resolve(strict=True)
    temporary = None
    if args.output:
        output = args.output.resolve()
        output.mkdir(parents=True, exist_ok=False)
    else:
        temporary = tempfile.TemporaryDirectory(prefix='glims-first-start-')
        output = Path(temporary.name)
    try:
        probe = output / 'engine-first-start-tests'
        subprocess.run(['xcrun', 'clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                        '-I', str(ROOT / 'Sources/CGlimsEngine/include'),
                        str(ROOT / 'Engine/tests/engine-first-start-tests.c'),
                        '-o', str(probe)], check=True)
        failed = False
        for case in ['absent', 'empty', 'present']:
            work = output / case
            work.mkdir(parents=True)
            # The version must be the missing leaf. An existing 3.2 parent
            # would itself be accepted as an old installation during scanning.
            user = work / 'user' / '3.2'
            user.parent.mkdir()
            environment = dict(os.environ)
            for key, leaf in [('HOME', 'home'), ('CFFIXED_USER_HOME', 'home'),
                              ('XDG_CACHE_HOME', 'cache'), ('XDG_CONFIG_HOME', 'config'),
                              ('XDG_DATA_HOME', 'data'), ('XDG_STATE_HOME', 'state'),
                              ('TMPDIR', 'tmp')]:
                (work / leaf).mkdir(exist_ok=True)
                environment[key] = str(work / leaf)
            environment['GIMP3_DIRECTORY'] = str(user)
            environment.pop('SNAP', None)
            environment.pop('SNAP_USER_DATA', None)
            if case == 'empty':
                environment['SNAP'] = ''
            elif case == 'present':
                environment['SNAP'] = str(work / 'missing snap root preserved verbatim')
            log = output / (case + '.log')
            with log.open('x') as stream:
                process = subprocess.Popen([str(probe), str(library), str(user),
                                            str(work / 'cache'), case], cwd=work,
                                           env=environment, stdin=subprocess.DEVNULL,
                                           stdout=stream, stderr=subprocess.STDOUT,
                                           start_new_session=True)
                try:
                    code = process.wait(timeout=120)
                except BaseException:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                    raise
            text = log.read_text()
            print(text, end='', flush=True)
            failed |= code != 0 or '-CRITICAL' in text
        print(f'{"FAILED" if failed else "PASSED"}: fresh startup SNAP absent/empty/present', flush=True)
        return int(failed)
    finally:
        if temporary:
            temporary.cleanup()


if __name__ == '__main__':
    raise SystemExit(main())
