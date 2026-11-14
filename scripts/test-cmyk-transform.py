#!/usr/bin/env python3
"""Check the private CMYK preview primitive against installed native libraries.

The external CMYK profile is read in place. This does not build upstream code
or start the app. Settings/caches and generated binaries use a throwaway home.
"""
import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    pinned = re.search(r'^ENGINE_SETS="([^:\s"]+)',
                       (ROOT / 'scripts/engine.env').read_text(), re.MULTILINE).group(1)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ref', default=pinned)
    parser.add_argument('--cmyk-profile', type=Path, required=True)
    parser.add_argument('--sanitize', action='store_true')
    args = parser.parse_args()
    install = (ROOT / '_engine/install' / args.ref).resolve()
    deps = (ROOT / '_deps/macports').resolve()
    profile = args.cmyk_profile.resolve(strict=True)
    if not profile.is_file() or not 128 <= profile.stat().st_size <= 4 * 1024 * 1024:
        parser.error('the external profile must be a regular ICC file between 128 bytes and 4 MB')
    if not (install / 'lib/libgimpcolor-3.0.0.dylib').is_file():
        parser.error(f'engine libraries are not installed at {install}')
    with tempfile.TemporaryDirectory(prefix='glims-cmyk-transform-') as temp:
        work = Path(temp)
        env = os.environ.copy()
        for key, child in [('HOME', 'home'), ('CFFIXED_USER_HOME', 'home'),
                           ('XDG_CACHE_HOME', 'cache'), ('XDG_CONFIG_HOME', 'config'),
                           ('XDG_DATA_HOME', 'data'), ('GIMP3_DIRECTORY', 'gimp'),
                           ('TMPDIR', 'tmp')]:
            (work / child).mkdir(exist_ok=True)
            env[key] = str(work / child)
        env['BABL_CACHE_DIR'] = str(work / 'cache/babl')
        env['PKG_CONFIG_LIBDIR'] = f'{install}/lib/pkgconfig:{deps}/lib/pkgconfig:{deps}/share/pkgconfig'
        env['PKG_CONFIG_PATH'] = ''
        packages = ['gegl-0.4', 'babl-0.1', 'lcms2', 'cairo', 'gdk-pixbuf-2.0', 'gobject-2.0']
        flags = shlex.split(subprocess.check_output(
            [str(deps / 'bin/pkg-config'), '--cflags', '--libs', *packages],
            env=env, text=True, timeout=30))
        compiler = ['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2']
        if args.sanitize:
            compiler += ['-O1', '-g', '-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-fno-omit-frame-pointer']
        command = compiler + ['-I', str(ROOT / 'Engine'), '-I', str(install / 'include/gimp-3.0'),
            str(ROOT / 'Engine/cmyk-transform.c'), str(ROOT / 'Engine/tests/cmyk-transform-tests.c'),
            str(install / 'lib/libgimpcolor-3.0.0.dylib'), str(install / 'lib/libgimpbase-3.0.0.dylib'),
            *flags, '-o', str(work / 'tests')]
        print('+', shlex.join(command), flush=True)
        subprocess.run(command, env=env, check=True, timeout=120)
        command = [str(work / 'tests'), str(profile)]
        print('+', shlex.join(command), flush=True)
        return subprocess.run(command, env=env, timeout=60).returncode


if __name__ == '__main__':
    raise SystemExit(main())
