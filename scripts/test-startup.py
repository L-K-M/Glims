#!/usr/bin/env python3
"""Check bundled startup catalog fidelity and native cache invalidation.

Uses disposable user directories and a cloned app; never changes the input
bundle. Ordinary GUI launch timing is a separate acceptance check.
"""
import argparse
import os
import re
import signal
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
        # This suite deliberately invalidates the original host seed. Exercise
        # alternate localized seeds separately in test-startup-localized-seeds.
        shutil.rmtree(clone / 'Contents/Resources/Engine-Startup/localized', ignore_errors=True)
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
        environment['GLIMS_STARTUP_LABEL_REPORT'] = str(work / 'labels.txt')
        environment['GLIMS_STARTUP_TRACE'] = '1'

        def run(label, seeded=False, temporary=False, tmpdir=None):
            (work / 'catalog.txt').unlink(missing_ok=True)
            run_env = environment.copy()
            if tmpdir is not None:
                run_env['TMPDIR'] = str(tmpdir)
                run_env.pop('GLIMS_TEST_UNDEFINED_PATH_TOKEN', None)
            result = subprocess.run([str(probe), str(clone / 'Contents/Frameworks/libglimsengine.dylib'),
                                     str(work / 'user'), str(work / 'cache')],
                                    env=run_env, cwd=work, capture_output=True, text=True, timeout=180)
            if result.returncode:
                raise AssertionError(f'{label}: exit {result.returncode}\n{result.stdout}\n{result.stderr}')
            marker = 'Glims: seeded bundled command cache' in result.stderr
            assert marker == seeded, f'{label}: unexpected command-cache seeding state'
            temporary_marker = 'Glims: using temporary bundled command cache' in result.stderr
            assert temporary_marker == temporary, f'{label}: unexpected temporary command-cache state'
            rc_file = work / 'user/gimprc'
            assert not rc_file.exists() or 'glims-pluginrc-' not in rc_file.read_text(), \
                f'{label}: temporary registry path leaked into preferences'
            assert not list((work / 'tmp').glob('glims-pluginrc-*')), f'{label}: temporary registry left behind'
            if tmpdir is not None:
                assert not list(Path(tmpdir).glob('glims-pluginrc-*')), f'{label}: temporary registry left behind'
            fonts, commands = (work / 'catalog.txt').read_text().split('[procedures]\n', 1)
            catalog = (frozenset(fonts.splitlines()[1:]), frozenset(commands.splitlines()))
            assert catalog[0] and catalog[1], f'{label}: empty catalog'
            print(f'{label}: {result.stdout.strip()}', flush=True)
            return catalog

        def unchanged(label, reference, seeded=False, temporary=False, tmpdir=None):
            actual = run(label, seeded, temporary, tmpdir)
            assert actual == reference, f'{label}: changed font or command catalog'

        baseline = run('fresh relocated bundle', True)
        unchanged('warm restart', baseline, False)
        (work / 'user/pluginrc').unlink()
        unchanged('missing command cache recovery', baseline, True)
        plugin_dir = work / 'user/plug-ins/glims-metadata-loader'
        plugin_dir.mkdir(parents=True)
        plugin = plugin_dir / 'glims-metadata-loader.py'
        plugin_source = (ROOT / 'Engine/tests/metadata-loader.py').read_text()
        original_label = "procedure.set_menu_label('Glims metadata oracle')"
        assert plugin_source.count(original_label) == 1
        plugin.write_text(plugin_source.replace(original_label,
            "procedure.set_menu_label(os.environ.get('GLIMS_TEST_METADATA_LABEL', 'Glims metadata oracle'))"))
        plugin.chmod(0o755)
        with_custom = run('user plug-in installed', False)
        assert 'plug-in-glims-meta-oracle' in with_custom[1], 'custom plug-in was not discovered'
        (work / 'user/pluginrc').unlink()
        unchanged('missing cache with user plug-in', with_custom, True)
        registry = work / 'user/pluginrc'
        valid_with_custom = registry.read_bytes()
        registry.write_text('invalid registry\n')
        unchanged('corrupt cache with user plug-in', with_custom, temporary=True)
        assert registry.read_text() == 'invalid registry\n', 'corrupt user registry was replaced'
        special_tmp = work / 'temporary ${GLIMS_TEST_UNDEFINED_PATH_TOKEN} ~ space'
        special_tmp.mkdir()
        unchanged('corrupt cache with user plug-in and special temporary path',
                  with_custom, temporary=True, tmpdir=special_tmp)
        unchanged('corrupt cache with trailing-slash temporary path',
                  with_custom, temporary=True, tmpdir=f'{special_tmp}/')
        assert registry.read_text() == 'invalid registry\n', 'corrupt user registry was replaced'
        # Two overlapping launches get distinct private registries. Each
        # must discover the user plug-in without replacing the shared file.
        processes = []
        try:
            for index in range(2):
                concurrent_env = environment.copy()
                concurrent_env['GLIMS_STARTUP_CATALOG_REPORT'] = str(work / f'catalog-concurrent-{index}.txt')
                concurrent_env.pop('GLIMS_STARTUP_LABEL_REPORT', None)
                processes.append(subprocess.Popen(
                    [str(probe), str(clone / 'Contents/Frameworks/libglimsengine.dylib'),
                     str(work / 'user'), str(work / 'cache')],
                    env=concurrent_env, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    text=True, start_new_session=True))
            for index, process in enumerate(processes):
                stdout, stderr = process.communicate(timeout=180)
                assert process.returncode == 0, f'concurrent launch {index}: {stdout}\n{stderr}'
                assert 'Glims: using temporary bundled command cache' in stderr, 'concurrent launch did not use a private registry'
                fonts, commands = (work / f'catalog-concurrent-{index}.txt').read_text().split('[procedures]\n', 1)
                assert (frozenset(fonts.splitlines()[1:]), frozenset(commands.splitlines())) == with_custom, \
                    'concurrent recovery changed the font or command catalog'
        finally:
            for process in processes:
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
        assert registry.read_text() == 'invalid registry\n', 'concurrent recovery replaced the user registry'
        assert not list((work / 'tmp').glob('glims-pluginrc-*')), 'concurrent recovery left a temporary registry'
        assert 'glims-pluginrc-' not in (work / 'user/gimprc').read_text(), 'concurrent recovery leaked a temporary path'
        print('concurrent corrupt-cache recovery: both catalogs preserved', flush=True)
        selected_rc = work / 'user/gimprc'
        prior_rc = selected_rc.read_bytes()
        selected_alternate = work / 'user/custom-alternate-pluginrc'
        selected_alternate.write_text('invalid registry\n')
        try:
            selected_rc.write_bytes(prior_rc + b'\n(pluginrc-path "${gimp_dir}/custom-alternate-pluginrc")\n')
            unchanged('corrupt alternate cache with user plug-in', with_custom, temporary=True)
            assert selected_alternate.read_text() == 'invalid registry\n', 'custom alternate registry was replaced'
            assert registry.read_text() == 'invalid registry\n', 'unselected default registry was replaced'
            selected_alternate.unlink()
            alternate_processes = []
            try:
                for index in range(2):
                    concurrent_env = environment.copy()
                    concurrent_env['GLIMS_STARTUP_CATALOG_REPORT'] = str(work / f'alternate-concurrent-{index}.txt')
                    concurrent_env.pop('GLIMS_STARTUP_LABEL_REPORT', None)
                    alternate_processes.append(subprocess.Popen(
                        [str(probe), str(clone / 'Contents/Frameworks/libglimsengine.dylib'),
                         str(work / 'user'), str(work / 'cache')],
                        env=concurrent_env, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        text=True, start_new_session=True))
                for index, process in enumerate(alternate_processes):
                    stdout, stderr = process.communicate(timeout=180)
                    assert process.returncode == 0, f'concurrent alternate launch {index}: {stdout}\n{stderr}'
                    fonts, commands = (work / f'alternate-concurrent-{index}.txt').read_text().split('[procedures]\n', 1)
                    assert (frozenset(fonts.splitlines()[1:]), frozenset(commands.splitlines())) == with_custom, \
                        'concurrent alternate launch changed the font or command catalog'
            finally:
                for process in alternate_processes:
                    if process.poll() is None:
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        process.wait()
            assert selected_alternate.is_file(), 'concurrent launch did not create the selected registry'
            assert registry.read_text() == 'invalid registry\n', 'concurrent alternate launch replaced the default registry'
            assert not list((work / 'tmp').glob('glims-pluginrc-*')), 'concurrent alternate recovery left a temporary registry'
            assert 'glims-pluginrc-' not in selected_rc.read_text(), 'concurrent alternate recovery leaked a temporary path'
            print('concurrent missing alternate recovery: both catalogs preserved', flush=True)
        finally:
            selected_rc.write_bytes(prior_rc)
            selected_alternate.unlink(missing_ok=True)
        registry.write_bytes(valid_with_custom)
        rc = work / 'user/gimprc'
        previous_rc = rc.read_bytes()
        changed_rc, replacements = re.subn(rb'\(prev-language "(?:[^"\\]|\\.)*"\)',
                                           b'(prev-language "glims-test-other-language")', previous_rc, count=1)
        assert replacements == 1, 'fixture is missing its previous-language setting'
        try:
            rc.write_bytes(changed_rc)
            # A valid registry with labels from the old language must not be
            # used as the current-language user plug-in catalog. The original
            # registry and its language tag remain paired across restarts.
            registry.write_bytes(valid_with_custom)
            environment['GLIMS_TEST_METADATA_LABEL'] = 'Fresh language oracle'
            unchanged('existing cache after language change', with_custom, temporary=True)
            assert 'plug-in-glims-meta-oracle\tFresh language oracle' in (work / 'labels.txt').read_text(), \
                'language-change recovery retained a stale user plug-in label'
            assert registry.read_bytes() == valid_with_custom, 'language-change recovery replaced the user registry'
            assert b'(prev-language "glims-test-other-language")' in rc.read_bytes(), \
                'language-change recovery detached the old registry from its language'
            unchanged('language-change recovery restart', with_custom, temporary=True)
            assert 'plug-in-glims-meta-oracle\tFresh language oracle' in (work / 'labels.txt').read_text(), \
                'restart reused stale user plug-in labels'
            assert registry.read_bytes() == valid_with_custom, 'restart replaced the user registry'
            language_processes = []
            try:
                for index in range(2):
                    concurrent_env = environment.copy()
                    concurrent_env['GLIMS_STARTUP_CATALOG_REPORT'] = str(work / f'language-catalog-{index}.txt')
                    concurrent_env['GLIMS_STARTUP_LABEL_REPORT'] = str(work / f'language-labels-{index}.txt')
                    language_processes.append(subprocess.Popen(
                        [str(probe), str(clone / 'Contents/Frameworks/libglimsengine.dylib'),
                         str(work / 'user'), str(work / 'cache')], env=concurrent_env, cwd=work,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True))
                for index, process in enumerate(language_processes):
                    stdout, stderr = process.communicate(timeout=180)
                    assert process.returncode == 0, f'language-change launch {index}: {stdout}\n{stderr}'
                    assert 'Glims: using temporary bundled command cache' in stderr, 'concurrent language launch did not use private registry'
                    fonts, commands = (work / f'language-catalog-{index}.txt').read_text().split('[procedures]\n', 1)
                    assert (frozenset(fonts.splitlines()[1:]), frozenset(commands.splitlines())) == with_custom, \
                        'concurrent language launch changed the catalog'
                    assert 'plug-in-glims-meta-oracle\tFresh language oracle' in (work / f'language-labels-{index}.txt').read_text(), \
                        'concurrent language launch retained a stale label'
            finally:
                for process in language_processes:
                    if process.poll() is None:
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        process.wait()
            assert registry.read_bytes() == valid_with_custom, 'concurrent language launches replaced the registry'
            assert b'(prev-language "glims-test-other-language")' in rc.read_bytes(), \
                'concurrent language launches detached the old registry from its language'
            assert not list((work / 'tmp').glob('glims-pluginrc-*')), 'concurrent language recovery left a temporary registry'
            print('concurrent language-change recovery: both catalogs and labels preserved', flush=True)
            alternate_language = work / 'user/language-alternate-pluginrc'
            alternate_language.write_bytes(valid_with_custom)
            rc.write_bytes(changed_rc + b'\n(pluginrc-path "${gimp_dir}/language-alternate-pluginrc")\n')
            unchanged('alternate cache after language change', with_custom, temporary=True)
            assert alternate_language.read_bytes() == valid_with_custom, 'language change replaced the alternate registry'
            assert b'(prev-language "glims-test-other-language")' in rc.read_bytes(), \
                'alternate registry lost its previous-language tag'
            assert 'plug-in-glims-meta-oracle\tFresh language oracle' in (work / 'labels.txt').read_text(), \
                'alternate recovery retained a stale user plug-in label'
            alternate_language.unlink()
            identity = clone / 'Contents/Resources/Engine-Startup/identity'
            compatible_identity = identity.read_bytes()
            try:
                identity.write_text('0.0.0\nincompatible-language\n')
                rc.write_bytes(changed_rc)
                registry.write_bytes(valid_with_custom)
                unchanged('language change with incompatible bundle', with_custom)
                assert 'plug-in-glims-meta-oracle\tFresh language oracle' in (work / 'labels.txt').read_text(), \
                    'native language-change fallback retained a stale user plug-in label'
                assert b'(prev-language "glims-test-other-language")' not in rc.read_bytes(), \
                    'native language-change fallback did not update the language tag'
            finally:
                identity.write_bytes(compatible_identity)
            rc.write_bytes(changed_rc)
            (work / 'user/pluginrc').unlink()
            unchanged('missing cache after language change', with_custom, True)
            assert 'plug-in-glims-meta-oracle\tFresh language oracle' in (work / 'labels.txt').read_text(), \
                'missing-cache recovery failed to query the user plug-in'
        finally:
            environment.pop('GLIMS_TEST_METADATA_LABEL', None)
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
            alternate.write_text('invalid registry\n')
            unchanged('corrupt alternate user registry', baseline, temporary=True)
            assert alternate.read_text() == 'invalid registry\n', 'corrupt alternate registry was replaced'
            assert not (work / 'user/pluginrc').exists(), 'created default cache for corrupt alternate registry'
            alternate.unlink()
            unchanged('missing alternate user registry', baseline, True)
            assert alternate.is_file(), 'selected alternate registry was not created'
            assert not (work / 'user/pluginrc').exists(), 'created default cache for missing alternate registry'
        finally:
            rc.write_bytes(original_rc)
            alternate.unlink(missing_ok=True)
        relative = work / 'user/relative-pluginrc'
        relative.write_text('invalid registry\n')
        try:
            rc.write_bytes(original_rc + b'\n(pluginrc-path "relative-pluginrc")\n')
            unchanged('corrupt relative user registry', baseline, temporary=True)
            assert relative.read_text() == 'invalid registry\n', 'relative registry was replaced'
            relative.unlink()
            unchanged('missing relative user registry', baseline, True)
            assert relative.is_file(), 'relative registry was not created in the user directory'
            assert not (work / 'user/pluginrc').exists(), 'created default cache for a relative registry'
        finally:
            rc.write_bytes(original_rc)
            relative.unlink(missing_ok=True)
        link_target = work / 'linked-pluginrc'
        link_target.write_text('invalid registry\n')
        (work / 'user/pluginrc').symlink_to(link_target)
        unchanged('corrupt symlinked registry', baseline, temporary=True)
        assert (work / 'user/pluginrc').is_symlink(), 'registry symlink was replaced'
        assert link_target.read_text() == 'invalid registry\n', 'registry symlink target was replaced'
        (work / 'user/pluginrc').unlink(missing_ok=True)
        (work / 'user/pluginrc').write_text('invalid registry\n')
        unchanged('corrupt cache with special temporary path', baseline, temporary=True, tmpdir=special_tmp)
        assert (work / 'user/pluginrc').read_text() == 'invalid registry\n', 'corrupt registry was replaced'
        identity = clone / 'Contents/Resources/Engine-Startup/identity'
        compatible_identity = identity.read_bytes()
        identity.write_text('0.0.0\nincompatible-language\n')
        (work / 'user/pluginrc').write_text('invalid registry\n')
        try:
            unchanged('corrupt registry with incompatible seed', baseline, False)
        finally:
            identity.write_bytes(compatible_identity)
        (work / 'user/pluginrc').write_text('invalid registry\n')
        unchanged('corrupt command cache recovery', baseline, temporary=True)
        assert (work / 'user/pluginrc').read_text() == 'invalid registry\n', 'corrupt registry was replaced'
        (work / 'user/pluginrc').write_bytes(valid_registry[:len(valid_registry)//2])
        unchanged('truncated command cache recovery', baseline, temporary=True)
        assert (work / 'user/pluginrc').read_bytes() == valid_registry[:len(valid_registry)//2], 'truncated registry was replaced'
        (work / 'user/pluginrc').write_bytes(valid_registry)
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
