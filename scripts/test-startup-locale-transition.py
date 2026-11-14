#!/usr/bin/env python3
"""Check command labels when an existing profile changes locale overrides.

The test clones the app and uses disposable profiles. An oracle plug-in's
menu label reveals whether GIMP reused a registry queried under another
locale environment; bundled menu labels are compared with fresh discovery.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='glims-locale-transition-') as folder:
        work = Path(folder)
        clone = work / 'Glims.app'
        subprocess.run(['cp', '-cpR', str(args.app.resolve()), str(clone)], check=True)
        contents = clone / 'Contents'
        probe = work / 'startup-tests'
        subprocess.run(['xcrun', 'clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                        '-I', str(ROOT / 'Sources/CGlimsEngine/include'),
                        str(ROOT / 'Engine/tests/startup-tests.c'), '-o', str(probe)], check=True)
        plugin = contents / 'lib/gimp/3.0/plug-ins/glims-metadata-loader/glims-metadata-loader.py'
        plugin.parent.mkdir(parents=True)
        source = (ROOT / 'Engine/tests/metadata-loader.py').read_text()
        original = "procedure.set_menu_label('Glims metadata oracle')"
        assert source.count(original) == 1
        plugin.write_text(source.replace(original,
            "procedure.set_menu_label(os.environ.get('GLIMS_TEST_METADATA_LABEL', 'missing oracle'))"))
        plugin.chmod(0o755)

        def run(profile, name, label, override, category=False, require_seed=False, language='fr'):
            profile.mkdir(exist_ok=True)
            env = os.environ.copy()
            for key in tuple(env):
                if key in ('LANG', 'LANGUAGE') or key.startswith('LC_'):
                    env.pop(key)
            for key, leaf in [('HOME', 'home'), ('CFFIXED_USER_HOME', 'home'),
                              ('XDG_CACHE_HOME', 'cache'), ('XDG_CONFIG_HOME', 'config'),
                              ('XDG_DATA_HOME', 'data'), ('XDG_STATE_HOME', 'state'),
                              ('GIMP3_DIRECTORY', 'user'), ('TMPDIR', 'tmp')]:
                (profile / leaf).mkdir(exist_ok=True)
                env[key] = str(profile / leaf)
            report_key = hashlib.sha256(name.encode()).hexdigest()[:16]
            catalog, labels_file = profile / f'catalog-{report_key}', profile / f'labels-{report_key}'
            env.update(GLIMS_STARTUP_TRACE='1', GLIMS_STARTUP_CATALOG_REPORT=str(catalog),
                       GLIMS_STARTUP_LABEL_REPORT=str(labels_file), GLIMS_TEST_METADATA_LABEL=label)
            if override == 'host':
                env.update({key: value for key, value in os.environ.items()
                            if key in ('LANG', 'LANGUAGE') or key.startswith('LC_')})
            elif override:
                env.update(LANGUAGE='de', LC_ALL='de_DE.UTF-8')
            if category:
                env['LC_TIME'] = 'fr_FR.UTF-8'
            start = time.monotonic()
            command = [str(probe), str(contents / 'Frameworks/libglimsengine.dylib'),
                       str(profile / 'user'), str(profile / 'cache')]
            if language is not None:
                command.extend(['-AppleLanguages', f'({language})'])
            result = subprocess.run(command, env=env, cwd=profile,
                                    capture_output=True, text=True, timeout=180)
            if result.returncode:
                raise AssertionError(f'{name}: exit {result.returncode}\n{result.stdout}\n{result.stderr}')
            if require_seed:
                assert 'Glims: seeded bundled command cache' in result.stderr, f'{name}: bundled seed was not used'
            lines = labels_file.read_text().splitlines()
            oracle = [line.split('\t', 1)[1] for line in lines if line.startswith('plug-in-glims-meta-oracle\t')]
            assert len(oracle) == 1, f'{name}: missing or duplicate oracle label'
            print(f'{name}: {time.monotonic() - start:.3f}s, oracle={oracle[0]!r}', flush=True)
            return oracle[0], {line for line in lines if not line.startswith('plug-in-glims-meta-oracle\t')}

        profile = work / 'profile'
        first, clean_labels = run(profile, 'initial', 'before override', False)
        assert first == 'before override'
        selected_registry = profile / 'user/pluginrc'
        original_registry = selected_registry.read_bytes()
        changed, changed_labels = run(profile, 'changed override', 'after override', True)
        fresh, fresh_labels = run(work / 'fresh', 'fresh override', 'fresh oracle', True)
        assert fresh == 'fresh oracle'
        assert changed == 'after override', 'changed locale override reused the previous plug-in query'
        assert changed_labels == fresh_labels, 'changed locale override reused stale bundled command labels'
        repeat, repeat_labels = run(profile, 'repeat override', 'unexpected re-query', True)
        assert repeat == 'after override' and repeat_labels == fresh_labels, 'matching override did not reuse its cache'
        assert selected_registry.read_bytes() == original_registry, 'override modified the selected registry'
        cache_root = profile / 'cache/glims-pluginrc-environments'
        matching = [p for p in cache_root.glob('*/pluginrc') if b'after override' in p.read_bytes()]
        assert len(matching) == 1, 'could not identify the override cache'
        cache = matching[0]
        legacy = work / 'legacy'
        (legacy / 'user').mkdir(parents=True)
        (legacy / 'user/pluginrc').write_bytes(cache.read_bytes())
        shutil.copy2(profile / 'user/gimprc', legacy / 'user/gimprc')
        legacy_bytes = (legacy / 'user/pluginrc').read_bytes()
        migrated, migrated_labels = run(legacy, 'legacy override registry', 'migrated clean oracle', False)
        assert migrated == 'migrated clean oracle' and migrated_labels == clean_labels, \
            'a registry from an older override was trusted on a clean launch'
        assert (legacy / 'user/pluginrc').read_bytes() == legacy_bytes, 'migration modified the selected legacy registry'
        bundled_seed = contents / 'Resources/Engine-Startup/pluginrc'
        seed_bytes = bundled_seed.read_bytes()
        try:
            bundled_seed.write_bytes(seed_bytes + b'\n# simulated bundle update\n')
            updated, updated_labels = run(profile, 'bundle seed changed', 'updated bundle oracle', True)
            assert updated == 'updated bundle oracle' and updated_labels == fresh_labels, \
                'a changed bundle reused the previous override cache'
        finally:
            bundled_seed.write_bytes(seed_bytes)
        bundled_identity = contents / 'Resources/Engine-Startup/identity'
        identity_bytes = bundled_identity.read_bytes()
        try:
            bundled_identity.write_bytes(identity_bytes + b'incompatible identity\n')
            changed_identity, changed_identity_labels = run(profile, 'bundle identity changed', 'identity oracle', True)
            assert changed_identity == 'identity oracle' and changed_identity_labels == fresh_labels, \
                'a changed bundle identity reused the previous override cache'
        finally:
            bundled_identity.write_bytes(identity_bytes)
        category, _ = run(profile, 'changed category', 'category oracle', True, category=True)
        assert category == 'category oracle', 'different LC category reused an incompatible query'
        category_repeat, _ = run(profile, 'repeat category', 'unexpected category query', True, category=True)
        assert category_repeat == 'category oracle', 'matching LC category did not reuse its cache'
        cache.write_bytes(b'invalid registry\n')
        recovered, recovered_labels = run(profile, 'corrupt override cache', 'recovered override', True)
        assert recovered == 'recovered override' and recovered_labels == fresh_labels, \
            'a corrupt override cache did not recover with correct labels'
        cache.unlink()
        sentinel = profile / 'sentinel'
        sentinel.write_text('keep this file')
        cache.symlink_to(sentinel)
        symlink_label, symlink_labels = run(profile, 'symlinked override cache', 'symlink oracle', True)
        assert symlink_label == 'symlink oracle' and symlink_labels == fresh_labels, \
            'a symlinked override cache did not fall back to fresh discovery'
        assert cache.is_symlink() and sentinel.read_text() == 'keep this file', 'symlink fallback modified the target'
        assert not list((profile / 'tmp').glob('glims-pluginrc-*')), 'temporary override registry was not removed'
        returned, _ = run(profile, 'return to clean environment', 'unexpected clean query', False)
        assert returned == 'before override', 'returning to the original environment reused override labels'
        assert selected_registry.read_bytes() == original_registry, 'environment transitions modified the selected registry'
        alternate = profile / 'user/alternate-pluginrc'
        alternate.write_bytes(original_registry)
        gimprc = profile / 'user/gimprc'
        gimprc.write_bytes(gimprc.read_bytes() + b'\n(pluginrc-path "${gimp_dir}/alternate-pluginrc")\n')
        alternate_label, alternate_labels = run(profile, 'alternate selected registry', 'alternate oracle', True)
        assert alternate_label == 'alternate oracle' and alternate_labels == fresh_labels, \
            'alternate selected registry reused an incompatible cache'
        alternate_repeat, _ = run(profile, 'repeat alternate override', 'unexpected alternate query', True)
        assert alternate_repeat == 'alternate oracle', 'alternate selected registry override was not cached'
        assert alternate.read_bytes() == original_registry, 'override modified the alternate selected registry'
        assert selected_registry.read_bytes() == original_registry, 'override modified the default selected registry'
        host_label, _ = run(work / 'host', 'matching host environment', 'host oracle', 'host',
                            require_seed=True, language=None)
        assert host_label == 'host oracle', 'matching host seed missed a newly installed plug-in'
        concurrent = work / 'concurrent'
        run(concurrent, 'concurrent baseline', 'baseline oracle', False)
        with ThreadPoolExecutor(max_workers=2) as pool:
            a = pool.submit(run, concurrent, 'concurrent override', 'concurrent oracle A', True)
            b = pool.submit(run, concurrent, 'concurrent category', 'concurrent oracle B', True, True)
            assert a.result()[0] == 'concurrent oracle A' and b.result()[0] == 'concurrent oracle B', \
                'overlapping different locale environments crossed command caches'
        cached_a, _ = run(concurrent, 'cached concurrent override', 'unexpected query A', True)
        cached_b, _ = run(concurrent, 'cached concurrent category', 'unexpected query B', True, category=True)
        assert cached_a == 'concurrent oracle A' and cached_b == 'concurrent oracle B', \
            'overlapping launches did not retain their separate locale caches'
        print('PASS: existing profile tracks locale override changes and reuses the matching cache')


if __name__ == '__main__':
    main()
