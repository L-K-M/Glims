#!/usr/bin/env python3
"""Check language-specific bundled registries with real macOS locales.

Uses a disposable, relocated bundle and home. The label supplied by a test
plug-in distinguishes a reused registry from a fresh native query.
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
    with tempfile.TemporaryDirectory(prefix='glims-startup-localized-') as temp:
        work = Path(temp)
        clone = work / 'Relocated Glims.app'
        subprocess.run(['cp', '-cpR', str(args.app.resolve()), str(clone)], check=True)
        contents = clone / 'Contents'
        startup = contents / 'Resources/Engine-Startup'
        # This suite specifically tests localized clean seeds and native
        # override fallback; exact override seeds have a separate suite.
        shutil.rmtree(startup / 'overrides', ignore_errors=True)
        version, host_language = (startup / 'identity').read_text().splitlines()[:2]
        probe = work / 'startup-tests'
        subprocess.run(['xcrun', 'clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                        '-I', str(ROOT / 'Sources/CGlimsEngine/include'),
                        str(ROOT / 'Engine/tests/startup-tests.c'), '-o', str(probe)], check=True)
        plugin_dir = contents / 'lib/gimp/3.0/plug-ins/glims-metadata-loader'
        plugin_dir.mkdir(parents=True)
        plugin = plugin_dir / 'glims-metadata-loader.py'
        original = "procedure.set_menu_label('Glims metadata oracle')"
        source = (ROOT / 'Engine/tests/metadata-loader.py').read_text()
        assert source.count(original) == 1
        plugin.write_text(source.replace(original,
            "procedure.set_menu_label(os.environ.get('GLIMS_TEST_METADATA_LABEL', 'missing oracle'))"))
        plugin.chmod(0o755)

        def run(name, language, label, seeded, override=None, category_override=False):
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
            environment.update({'GLIMS_STARTUP_TRACE': '1', 'GLIMS_STARTUP_CATALOG_REPORT': str(profile / 'catalog'),
                                'GLIMS_STARTUP_LABEL_REPORT': str(profile / 'labels'),
                                'GLIMS_TEST_METADATA_LABEL': label})
            if override:
                environment.update(LANGUAGE=override, LC_ALL=f'{override}_{override.upper()}.UTF-8')
            if category_override:
                environment['LC_TIME'] = 'de_DE.UTF-8'
            result = subprocess.run([str(probe), str(contents / 'Frameworks/libglimsengine.dylib'),
                                     str(profile / 'user'), str(profile / 'cache'),
                                     '-AppleLanguages', f'({language})'],
                                    env=environment, cwd=profile, capture_output=True, text=True, timeout=180)
            if result.returncode:
                raise AssertionError(f'{name}: exit {result.returncode}\n{result.stdout}\n{result.stderr}')
            assert f'(prev-language "{language}")' in (profile / 'user/gimprc').read_text()
            assert ('Glims: seeded bundled command cache' in result.stderr) == seeded, \
                f'{name}: unexpected registry seeding\n{result.stderr}'
            labels = (profile / 'labels').read_text().splitlines()
            oracle = [line.split('\t', 1)[1] for line in labels if line.startswith('plug-in-glims-meta-oracle\t')]
            assert len(oracle) == 1, f'{name}: missing or duplicate oracle label'
            print(f'{name}: {result.stdout.strip()}; {oracle[0]}', flush=True)
            return profile, oracle[0]

        # Verify real packaged seeds also discover newly installed plug-ins.
        packaged_labels = {}
        # Exercise two single-language seeds distinct from the host, plus
        # both exact lists. A list matching the host uses its host seed.
        packaged_languages = (tuple(language for language in ('fr', 'de', 'en')
                                    if language != host_language)[:2] +
                              ('en-US,en', 'de-CH,de,en'))
        for language in packaged_languages:
            profile, label = run(f'{language}-packaged', language, f'new {language} plug-in', True)
            assert label == f'new {language} plug-in'
            packaged_labels[language] = {line for line in (profile / 'labels').read_text().splitlines()
                                         if not line.startswith('plug-in-glims-meta-oracle\t')}
        # A matching first language is insufficient when fallback order differs.
        unshipped = next(language for language in ('de-CH,en,de', 'en-US,fr,en')
                         if language != host_language)
        _, label = run('different-fallback-order', unshipped, 'fresh fallback oracle', False)
        assert label == 'fresh fallback oracle'
        # A strict prefix must not select the longer list's registry either.
        prefix = next(language for language in ('de-CH,de', 'en-US')
                      if language != host_language)
        _, label = run('prefix-of-seed-list', prefix, 'fresh prefix oracle', False)
        assert label == 'fresh prefix oracle'
        shutil.rmtree(startup / 'localized', ignore_errors=True)
        (startup / 'identity').write_text('0.0.0\nincompatible-language\n')

        for language in dict.fromkeys((*packaged_languages, 'fr', 'de')):
            profile, label = run(f'{language}-discovery', language, f'{language} oracle', False)
            assert label == f'{language} oracle'
            discovered_labels = {line for line in (profile / 'labels').read_text().splitlines()
                                 if not line.startswith('plug-in-glims-meta-oracle\t')}
            if language in packaged_labels:
                assert packaged_labels[language] == discovered_labels, f'{language}: cached labels differ from discovery'
            seed = startup / 'localized' / hashlib.sha256(language.encode()).hexdigest()
            seed.mkdir(parents=True)
            (seed / 'identity').write_text(f'{version}\n{language}\n')
            (seed / 'pluginrc').write_bytes((profile / 'user/pluginrc').read_bytes().replace(
                contents.as_uri().encode(), b'@GLIMS_BUNDLE_URI@'))
            _, label = run(f'{language}-seed', language, 'unexpected fresh query', True)
            assert label == f'{language} oracle', 'matching language seed did not preserve its label'

        # macOS reports the same preferred language list even if an explicit
        # environment override changes gettext labels. Never reuse that seed.
        _, label = run('locale-override', 'fr', 'override oracle', False, override='de')
        assert label == 'override oracle'
        _, label = run('category-override', 'fr', 'category override oracle', False, category_override=True)
        assert label == 'category override oracle'

        # The original host-seed location needs the same protection.
        french_seed = startup / 'localized' / hashlib.sha256(b'fr').hexdigest()
        (startup / 'identity').write_text(f'{version}\nfr\n')
        shutil.copy2(french_seed / 'pluginrc', startup / 'pluginrc')
        clean_environment = hashlib.sha256()
        for key in ('LANG', 'LANGUAGE'):
            clean_environment.update(key.encode() + b'\0\0')
        (startup / 'environment').write_text(clean_environment.hexdigest() + '\n')
        _, label = run('host-seed', 'fr', 'unexpected host query', True)
        assert label == 'fr oracle'
        _, label = run('host-locale-override', 'fr', 'host override oracle', False, override='de')
        assert label == 'host override oracle'
        _, label = run('host-category-override', 'fr', 'host category oracle', False, category_override=True)
        assert label == 'host category oracle'

        # Hash path alone never authenticates an identity: a mislabelled seed
        # must cause native discovery rather than publish the wrong language.
        bad = startup / 'localized' / hashlib.sha256(b'de').hexdigest() / 'identity'
        bad.write_text(f'{version}\nfr\n')
        _, label = run('bad-identity', 'de', 'fresh German oracle', False)
        assert label == 'fresh German oracle'
        print('PASS: per-language registry identity and localized labels')


if __name__ == '__main__':
    main()
