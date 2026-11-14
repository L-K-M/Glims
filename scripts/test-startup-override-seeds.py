#!/usr/bin/env python3
"""Check exact bundled locale-override seeds against native discovery.

Uses a relocated disposable app and independent profiles. The oracle plug-in
is added after packaging so a matching seed must still discover it.
"""
import argparse
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
    with tempfile.TemporaryDirectory(prefix='glims-override-seed-') as folder:
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

        def run(name, label, category=False, language='de', locale='de_DE.UTF-8', launch_defaults=False):
            profile = work / name
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
            env.update(LANGUAGE=language, LC_ALL=locale, GLIMS_STARTUP_TRACE='1',
                       GLIMS_STARTUP_CATALOG_REPORT=str(profile / 'catalog'),
                       GLIMS_STARTUP_LABEL_REPORT=str(profile / 'labels'), GLIMS_TEST_METADATA_LABEL=label)
            if launch_defaults:
                env.update(LANG='C.UTF-8', LC_CTYPE='C.UTF-8')
            if category:
                env['LC_TIME'] = 'fr_FR.UTF-8'
            start = time.monotonic()
            result = subprocess.run([str(probe), str(contents / 'Frameworks/libglimsengine.dylib'),
                                     str(profile / 'user'), str(profile / 'cache')], env=env, cwd=profile,
                                    capture_output=True, text=True, timeout=180)
            if result.returncode:
                raise AssertionError(f'{name}: exit {result.returncode}\n{result.stdout}\n{result.stderr}')
            lines = (profile / 'labels').read_text().splitlines()
            oracle = [line.split('\t', 1)[1] for line in lines if line.startswith('plug-in-glims-meta-oracle\t')]
            assert oracle == [label], f'{name}: user plug-in was not discovered'
            seeded = 'Glims: seeded bundled command cache' in result.stderr
            print(f'{name}: {time.monotonic() - start:.3f}s, seeded={seeded}', flush=True)
            return seeded, {line for line in lines if not line.startswith('plug-in-glims-meta-oracle\t')}

        host_identity = contents / 'Resources/Engine-Startup/identity'
        host_bytes = host_identity.read_bytes()
        escaped_language = host_bytes.decode().splitlines()[1]
        def identity_for(environment):
            fingerprint = hashlib.sha256()
            for name in sorted({'LANG', 'LANGUAGE'} | set(environment), key=os.fsencode):
                value = environment.get(name)
                fingerprint.update(name.encode() + b'\0' + (b'\1' if value is not None else b'\0'))
                if value is not None:
                    fingerprint.update(value.encode() + b'\0')
            value = fingerprint.hexdigest()
            key = hashlib.sha256(escaped_language.encode() + b'\0' + value.encode() + b'\0').hexdigest()
            return key, value
        pairs = (('en', 'en_US.UTF-8'), ('de', 'de_DE.UTF-8'), ('fr', 'fr_FR.UTF-8'),
                 ('it', 'it_IT.UTF-8'), ('es', 'es_ES.UTF-8'), ('ja', 'ja_JP.UTF-8'))
        for code, locale in pairs:
            for launch_defaults in (False, True):
                environment = {'LANGUAGE': code, 'LC_ALL': locale}
                if launch_defaults:
                    environment.update(LANG='C.UTF-8', LC_CTYPE='C.UTF-8')
                key, fingerprint = identity_for(environment)
                seed = contents / 'Resources/Engine-Startup/overrides' / key
                label = f'{code} launch={launch_defaults}'
                assert (seed / 'identity').read_bytes() == host_bytes, f'{label}: wrong override identity'
                assert (seed / 'environment').read_text() == fingerprint + '\n', f'{label}: wrong override environment'
                assert (seed / 'pluginrc').is_file(), f'{label}: missing override registry'
        # The host seed must not mask a missing override seed when the build
        # machine happens to have this exact locale environment itself.
        host_identity.write_text('0.0.0\nincompatible\n')
        seeded, seeded_labels = run('matching', 'matching oracle')
        assert seeded, 'exact common locale override did not use a packaged seed'
        seeded_catalogs = {('de', False): seeded_labels}
        for code, locale in pairs:
            for launch_defaults in (False, True):
                if code == 'de' and not launch_defaults:
                    continue
                label = f'{code}-launch-{launch_defaults}'
                matched, labels = run(f'matching-{label}', f'{label} oracle', language=code,
                                      locale=locale, launch_defaults=launch_defaults)
                assert matched, f'{label}: exact locale override did not use a packaged seed'
                seeded_catalogs[code, launch_defaults] = labels
        key, _ = identity_for({'LANGUAGE': 'de', 'LC_ALL': 'de_DE.UTF-8'})
        override_registry = contents / 'Resources/Engine-Startup/overrides' / key / 'pluginrc'
        original_registry = override_registry.read_bytes()
        try:
            override_registry.write_bytes(original_registry + b'\n# simulated bundle update\n')
            updated, updated_labels = run('matching', 'updated seed oracle')
            assert updated and updated_labels == seeded_labels, 'changed override seed did not refresh the cached registry'
        finally:
            override_registry.write_bytes(original_registry)
        unmatched, _ = run('extra-category', 'category oracle', category=True)
        assert not unmatched, 'a different LC category reused the exact override seed'
        environment = {'LANGUAGE': 'de', 'LC_ALL': 'de_DE.UTF-8'}
        key, _ = identity_for(environment)
        override_identity = contents / 'Resources/Engine-Startup/overrides' / key / 'identity'
        override_bytes = override_identity.read_bytes()
        try:
            override_identity.write_text('0.0.0\nincompatible\n')
            invalid, invalid_labels = run('invalid-identity', 'invalid identity oracle')
            assert not invalid and invalid_labels == seeded_labels, 'invalid override identity was trusted'
        finally:
            host_identity.write_bytes(host_bytes)
            override_identity.write_bytes(override_bytes)
        shutil.rmtree(contents / 'Resources/Engine-Startup/overrides')
        # Prevent a matching host seed from masking native discovery on a host
        # whose build environment happens to equal this override.
        host_identity.write_text('0.0.0\nincompatible\n')
        for code, locale in pairs:
            for launch_defaults in (False, True):
                label = f'{code}-launch-{launch_defaults}'
                discovered, discovered_labels = run(f'discovery-{label}', f'fresh {label} oracle',
                                                      language=code, locale=locale, launch_defaults=launch_defaults)
                assert not discovered, f'{label}: a packaged seed matched when native discovery was required'
                assert seeded_catalogs[code, launch_defaults] == discovered_labels, \
                    f'{label}: override seed differs from native discovery'
        print('PASS: exact locale override seed matches native discovery and refuses unmatched environments')


if __name__ == '__main__':
    main()
