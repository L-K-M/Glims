#!/usr/bin/env python3
"""Exercise real macOS language changes with a deterministic bundled plug-in.

Runs only disposable profiles and a relocated clone of the supplied app. The
negative oracle intentionally mislabels the clone's seed; it must demonstrate
why the production language identity check is necessary. No GUI is opened.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    app = args.app.resolve()
    if not (app / 'Contents/Frameworks/libglimsengine.dylib').is_file():
        parser.error('the app must contain a bundled engine')
    with tempfile.TemporaryDirectory(prefix='glims-startup-real-locale-') as temporary:
        work = Path(temporary)
        clone = work / 'Relocated Glims.app'
        subprocess.run(['cp', '-cpR', str(app), str(clone)], check=True)
        contents = clone / 'Contents'
        adapter = contents / 'Frameworks/libglimsengine.dylib'
        startup = contents / 'Resources/Engine-Startup'
        identity = startup / 'identity'
        registry = startup / 'pluginrc'
        version = identity.read_text().splitlines()[0]
        probe = work / 'startup-tests'
        subprocess.run(['xcrun', 'clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                        '-I', str(ROOT / 'Sources/CGlimsEngine/include'),
                        str(ROOT / 'Engine/tests/startup-tests.c'), '-o', str(probe)], check=True)
        # This plug-in is inside the cloned bundle, so a matching seed can
        # legitimately reuse its unchanged query output rather than rescan it.
        plugin_dir = contents / 'lib/gimp/3.0/plug-ins/glims-metadata-loader'
        plugin_dir.mkdir(parents=True)
        plugin = plugin_dir / 'glims-metadata-loader.py'
        source = (ROOT / 'Engine/tests/metadata-loader.py').read_text()
        original = "procedure.set_menu_label('Glims metadata oracle')"
        assert source.count(original) == 1
        plugin.write_text(source.replace(original,
            "procedure.set_menu_label(os.environ.get('GLIMS_TEST_METADATA_LABEL', 'missing oracle'))"))
        plugin.chmod(0o755)

        def run(name, language, label, seeded):
            profile = work / name
            profile.mkdir()
            environment = os.environ.copy()
            for key in tuple(environment):
                if key in ('LANG', 'LANGUAGE') or key.startswith('LC_'):
                    environment.pop(key)
            for key, leaf in [('HOME', 'home'), ('CFFIXED_USER_HOME', 'home'),
                              ('XDG_CACHE_HOME', 'cache'), ('XDG_CONFIG_HOME', 'config'),
                              ('XDG_DATA_HOME', 'data'), ('XDG_STATE_HOME', 'state'),
                              ('GIMP3_DIRECTORY', 'user'), ('TMPDIR', 'tmp')]:
                (profile / leaf).mkdir(exist_ok=True)
                environment[key] = str(profile / leaf)
            environment.update({'GLIMS_STARTUP_TRACE': '1',
                                'GLIMS_STARTUP_CATALOG_REPORT': str(profile / 'catalog'),
                                'GLIMS_STARTUP_LABEL_REPORT': str(profile / 'labels'),
                                'GLIMS_TEST_METADATA_LABEL': label})
            result = subprocess.run([str(probe), str(adapter), str(profile / 'user'),
                                     str(profile / 'cache'), '-AppleLanguages', f'({language})'],
                                    env=environment, cwd=profile, capture_output=True,
                                    text=True, timeout=180)
            if result.returncode:
                raise AssertionError(f'{name}: exit {result.returncode}\n{result.stdout}\n{result.stderr}')
            assert f'(prev-language "{language}")' in (profile / 'user/gimprc').read_text(), \
                f'{name}: macOS did not select requested language'
            assert ('Glims: seeded bundled command cache' in result.stderr) == seeded, \
                f'{name}: unexpected registry seeding'
            labels = (profile / 'labels').read_text().splitlines()
            oracle = [line for line in labels if line.startswith('plug-in-glims-meta-oracle\t')]
            assert len(oracle) == 1, f'{name}: missing or duplicate oracle label'
            print(f'{name}: {result.stdout.strip()}; {oracle[0]}', flush=True)
            return profile, oracle[0].split('\t', 1)[1]

        # Exercise only the root seed and a locale-free process environment;
        # packaged per-language and override seeds would mask this oracle.
        shutil.rmtree(startup / 'localized', ignore_errors=True)
        shutil.rmtree(startup / 'overrides', ignore_errors=True)
        fingerprint = hashlib.sha256()
        for key in ('LANG', 'LANGUAGE'):
            fingerprint.update(key.encode() + b'\0\0')
        (startup / 'environment').write_text(fingerprint.hexdigest() + '\n')
        identity.write_text('0.0.0\nincompatible-language\n')
        french, label = run('French discovery', 'fr', 'French oracle', False)
        assert label == 'French oracle'
        # Match the packager's relocation rule when turning the discovered
        # registry into a bundle seed. It now represents the French language.
        registry.write_bytes((french / 'user/pluginrc').read_bytes().replace(
            contents.as_uri().encode(), b'@GLIMS_BUNDLE_URI@'))
        identity.write_text(version + '\nfr\n')
        _, label = run('French seed', 'fr', 'changed label must not be queried', True)
        assert label == 'French oracle', 'matching seed did not reuse the bundled plug-in'
        _, label = run('German discovery', 'de', 'German oracle', False)
        assert label == 'German oracle', 'a wrong-language seed hid the German plug-in label'
        # Negative control: falsely tag French bytes as German and demonstrate
        # that accepting those bytes would expose the stale French label.
        identity.write_text(version + '\nde\n')
        _, label = run('Deliberately mislabelled seed', 'de', 'German oracle', True)
        assert label == 'French oracle', 'negative control failed to expose the stale label'
        print('PASS: actual macOS language identity prevents stale bundled plug-in labels')


if __name__ == '__main__':
    main()
