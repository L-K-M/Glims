#!/usr/bin/env python3
"""Check bundled startup catalog fidelity and native cache invalidation.

Uses disposable user directories and a cloned app; never changes the input
bundle. Ordinary GUI launch timing is a separate acceptance check.
"""
import argparse
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--font', type=Path, default=ROOT / '_deps/macports/share/ghostscript/10.08.0/Resource/CIDFSubst/DroidSansFallback.ttf')
    args = parser.parse_args()
    if not args.font.is_file():
        parser.error('supply the Droid Sans Fallback fixture with --font')
    app = args.app.resolve()
    with tempfile.TemporaryDirectory(prefix='glims-startup-check-') as temporary:
        work = Path(temporary)
        clone = work / 'Relocated Glims.app'
        # Native plug-in cache identity includes executable mtimes. A plain
        # recursive copy changes them and silently tests only requery fallback.
        subprocess.run(['cp', '-cpR', str(app), str(clone)], check=True)
        probe = work / 'startup-tests'
        subprocess.run(['xcrun', 'clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                        '-I', str(ROOT / 'Sources/CGlimsEngine/include'),
                        str(ROOT / 'Engine/tests/startup-tests.c'), '-o', str(probe)], check=True)
        environment = dict(os.environ)
        for key, leaf in [('HOME', 'home'), ('CFFIXED_USER_HOME', 'home'),
                          ('XDG_CACHE_HOME', 'cache'), ('XDG_CONFIG_HOME', 'config'),
                          ('XDG_DATA_HOME', 'data'), ('XDG_STATE_HOME', 'state'),
                          ('GIMP3_DIRECTORY', 'user'), ('TMPDIR', 'tmp')]:
            (work / leaf).mkdir(exist_ok=True)
            environment[key] = str(work / leaf)
        environment['GLIMS_STARTUP_CATALOG_REPORT'] = str(work / 'catalog.txt')
        environment['GLIMS_STARTUP_TRACE'] = '1'

        def run(label, seeded=None):
            (work / 'catalog.txt').unlink(missing_ok=True)
            result = subprocess.run([str(probe), str(clone / 'Contents/Frameworks/libglimsengine.dylib'),
                                     str(work / 'user'), str(work / 'cache')],
                                    env=environment, cwd=work, capture_output=True, text=True, timeout=180)
            if result.returncode:
                raise AssertionError(f'{label}: {result.stdout}\n{result.stderr}')
            marker = 'Glims: seeded bundled command cache' in result.stderr
            if seeded is not None:
                assert marker == seeded, f'{label}: unexpected command-cache seeding state'
            fonts, commands = (work / 'catalog.txt').read_text().split('[procedures]\n', 1)
            catalog = (frozenset(fonts.splitlines()[1:]), frozenset(commands.splitlines()))
            assert catalog[0] and catalog[1], f'{label}: empty catalog'
            print(f'{label}: {result.stdout.strip()}', flush=True)
            return catalog

        def unchanged(label, reference, seeded=None):
            actual = run(label, seeded)
            assert actual == reference, f'{label}: changed font or command catalog'

        baseline = run('fresh relocated bundle', True)
        unchanged('warm restart', baseline, False)
        (work / 'user/pluginrc').unlink()
        unchanged('missing command cache recovery', baseline, True)
        plugin_dir = work / 'user/plug-ins/glims-metadata-loader'
        plugin_dir.mkdir(parents=True)
        plugin = plugin_dir / 'glims-metadata-loader.py'
        shutil.copy2(ROOT / 'Engine/tests/metadata-loader.py', plugin)
        plugin.chmod(0o755)
        with_custom = run('user plug-in installed', False)
        assert 'plug-in-glims-meta-oracle' in with_custom[1], 'custom plug-in was not discovered'
        (work / 'user/pluginrc').unlink()
        unchanged('missing cache with user plug-in', with_custom, True)
        rc = work / 'user/gimprc'
        previous_rc = rc.read_bytes()
        changed_rc, replacements = re.subn(rb'\(prev-language "(?:[^"\\]|\\.)*"\)',
                                           b'(prev-language "glims-test-other-language")', previous_rc, count=1)
        assert replacements == 1, 'fixture is missing its previous-language setting'
        try:
            rc.write_bytes(changed_rc)
            (work / 'user/pluginrc').unlink()
            unchanged('missing cache after language change', with_custom, False)
        finally:
            rc.write_bytes(previous_rc)
        shutil.rmtree(plugin_dir)
        unchanged('user plug-in removed', baseline)
        valid_registry = (work / 'user/pluginrc').read_bytes()
        # A configured registry belongs to the user. Do not manufacture the
        # default file just because it is absent while this path is active.
        rc = work / 'user/gimprc'
        original_rc = rc.read_bytes()
        alternate = work / 'user/alternate-pluginrc'
        shutil.copy2(work / 'user/pluginrc', alternate)
        (work / 'user/pluginrc').unlink()
        try:
            rc.write_bytes(original_rc + b'\n(pluginrc-path "${gimp_dir}/alternate-pluginrc")\n')
            unchanged('alternate user registry', baseline, False)
            assert not (work / 'user/pluginrc').exists(), 'created default cache despite alternate registry'
        finally:
            rc.write_bytes(original_rc)
            alternate.unlink(missing_ok=True)
        (work / 'user/pluginrc').write_text('invalid registry\n')
        unchanged('corrupt command cache recovery', baseline, False)
        (work / 'user/pluginrc').write_bytes(valid_registry[:len(valid_registry)//2])
        unchanged('truncated command cache recovery', baseline, False)
        caches = list((work / 'cache/fontconfig').glob('*.cache-*'))
        assert caches, 'no native font caches were generated'
        for cache in caches:
            cache.write_bytes(b'invalid cache')
        unchanged('corrupt font cache recovery', baseline)
        assert not any('Droid Sans Fallback' in name for name in baseline[0]), 'fixture font already present'
        fonts = work / 'home/Library/Fonts'
        fonts.mkdir(parents=True)
        installed = fonts / args.font.name
        shutil.copy2(args.font, installed)
        added = run('user font added after cached launch')
        assert any('Droid Sans Fallback' in name for name in added[0]), 'new user font was not discovered'
        assert added[1] == baseline[1], 'font installation changed commands'
        installed.unlink()
        unchanged('user font removed after cached launch', baseline)
        # An incompatible packaged registry must use normal plug-in discovery.
        shutil.rmtree(work / 'user')
        (work / 'user').mkdir()
        identity = clone / 'Contents/Resources/Engine-Startup/identity'
        identity.write_text('0.0.0\nincompatible-language\n')
        unchanged('incompatible packaged registry fallback', baseline, False)
        # A missing optional helper keeps the original native font config.
        (clone / 'Contents/MacOS/glims-font-cache').unlink()
        shutil.rmtree(work / 'cache')
        (work / 'cache').mkdir()
        unchanged('missing font helper fallback', baseline)
        print('PASS: startup catalogs, cache recovery, relocation and user font changes')


if __name__ == '__main__':
    main()
