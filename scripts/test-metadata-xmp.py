#!/usr/bin/env python3
"""Exercise the adapter's pure XMP comparator without starting an engine."""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
prefix = root / '_deps' / 'macports'
environment = os.environ.copy()
environment['PKG_CONFIG_LIBDIR'] = str(prefix / 'lib' / 'pkgconfig')
flags = shlex.split(subprocess.check_output(
    [str(prefix / 'bin' / 'pkg-config'), '--cflags', '--libs', 'glib-2.0'],
    env=environment, text=True))
with tempfile.TemporaryDirectory(prefix='glims-xmp-tests-') as temporary:
    binary = str(Path(temporary) / 'metadata-xmp-tests')
    subprocess.run(['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra',
                    '-Wno-unused-parameter', '-Werror',
                    str(root / 'Engine' / 'metadata-xmp.c'),
                    str(root / 'Engine' / 'tests' / 'metadata-xmp-tests.c'),
                    *flags, '-o', binary], check=True)
    subprocess.run([binary], check=True)
