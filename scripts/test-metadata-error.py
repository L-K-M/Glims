#!/usr/bin/env python3
"""Inject a real native error and count its releases without double freeing."""
from pathlib import Path
import os
import shlex
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
if len(sys.argv) != 2:
    raise SystemExit('usage: python3 scripts/test-metadata-error.py ADAPTER_LIBRARY')
adapter = str(Path(sys.argv[1]).resolve())
prefix = root / '_deps' / 'macports'
env = os.environ.copy()
env['PKG_CONFIG_LIBDIR'] = str(prefix / 'lib' / 'pkgconfig')
flags = shlex.split(subprocess.check_output(
    [str(prefix / 'bin' / 'pkg-config'), '--cflags', '--libs', 'gexiv2'], env=env, text=True))
with tempfile.TemporaryDirectory(prefix='glims-metadata-error-') as temporary:
    work = Path(temporary)
    shim = work / 'error-injection.dylib'
    runner = work / 'metadata-error-tests'
    subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror','-dynamiclib',
        str(root / 'Engine/tests/metadata-error-interpose.c'),*flags,'-o',str(shim)],check=True)
    subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror',
        '-I'+str(root / 'Sources/CGlimsEngine/include'),
        str(root / 'Engine/tests/metadata-error-tests.c'),'-o',str(runner)],check=True)
    for child in ['home','user','cache']: (work/child).mkdir()
    env.update(HOME=str(work/'home'), XDG_CACHE_HOME=str(work/'cache'),
               DYLD_INSERT_LIBRARIES=str(shim))
    result = subprocess.run([str(runner),adapter,str(work/'user'),str(work/'cache')],
                            env=env,timeout=90)
    raise SystemExit(result.returncode)
