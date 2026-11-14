"""Query the finished bundle and package relocatable command registries.

Run after inner-code signing (which can change executable mtimes), before
outer app signing. No build paths, user preferences, or font caches are shipped.
"""
from pathlib import Path
import hashlib
import os
import re
import subprocess
import sys
import tempfile

# Each seed is captured for the entire macOS preference list, including its
# order. Other lists still use native discovery; a partial match is not safe.
LOCALIZED_SEEDS = ('en', 'de', 'fr', 'it', 'es', 'ja',
                   'en-US,en', 'de-CH,de,en')
OVERRIDE_SEEDS = (('en', 'en_US.UTF-8'), ('de', 'de_DE.UTF-8'),
                  ('fr', 'fr_FR.UTF-8'), ('it', 'it_IT.UTF-8'),
                  ('es', 'es_ES.UTF-8'), ('ja', 'ja_JP.UTF-8'))


def locale_environment_keys(environment):
    return sorted({'LANG', 'LANGUAGE'} | {key for key in environment if key.startswith('LC_')},
                  key=os.fsencode)


def locale_environment_fingerprint(environment):
    digest = hashlib.sha256()
    for key in locale_environment_keys(environment):
        digest.update(os.fsencode(key) + b'\0')
        if key in environment:
            digest.update(b'\1' + os.fsencode(environment[key]) + b'\0')
        else:
            digest.update(b'\0')
    return digest.hexdigest()


def override_seed_key(escaped_language, environment):
    fingerprint = locale_environment_fingerprint(environment)
    return hashlib.sha256(escaped_language.encode('utf-8') + b'\0' + fingerprint.encode('ascii') + b'\0').hexdigest()


def prepare(app):
    source = Path(__file__).resolve().parents[1]
    contents = Path(app).resolve() / "Contents"
    destination = contents / "Resources/Engine-Startup"
    if destination.exists():
        raise RuntimeError("Startup registry already exists; generate it only in a fresh app assembly")
    with tempfile.TemporaryDirectory(prefix="glims-startup-build-") as temporary:
        work = Path(temporary)
        probe = work / "startup-tests"
        subprocess.run(["xcrun", "clang", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-I", str(source / "Sources/CGlimsEngine/include"),
                        str(source / "Engine/tests/startup-tests.c"), "-o", str(probe)], check=True)
        def capture(name, language=None, clean_locale=False, locale_override=None):
            profile = work / name
            profile.mkdir()
            environment = dict(os.environ)
            for key in ("GLIMS_STARTUP_TRACE", "GLIMS_STARTUP_CATALOG_REPORT", "GLIMS_STARTUP_LABEL_REPORT"):
                environment.pop(key, None)
            # Confine each native query to its own disposable home and cache.
            for key, leaf in [("HOME", "home"), ("CFFIXED_USER_HOME", "home"),
                              ("XDG_CACHE_HOME", "cache"), ("XDG_CONFIG_HOME", "config"),
                              ("XDG_DATA_HOME", "data"), ("XDG_STATE_HOME", "state"),
                              ("GIMP3_DIRECTORY", "user"), ("TMPDIR", "tmp")]:
                (profile / leaf).mkdir(exist_ok=True)
                environment[key] = str(profile / leaf)
            command = [str(probe), str(contents / "Frameworks/libglimsengine.dylib"),
                       str(profile / "user"), str(profile / "cache")]
            if language or clean_locale or locale_override is not None:
                # The runtime accepts these extra seeds only in this same
                # environment, because gettext overrides are not represented
                # by macOS's preferred-language-list identity.
                for key in locale_environment_keys(environment):
                    environment.pop(key, None)
            if locale_override is not None:
                environment.update(locale_override)
            if language:
                command.extend(["-AppleLanguages", f"({language})"])
            result = subprocess.run(command, env=environment, cwd=profile, text=True,
                                    capture_output=True, timeout=180)
            if result.returncode:
                raise RuntimeError(f"Bundled engine startup failed for {name}:\n{result.stdout}\n{result.stderr}")
            rc = (profile / "user/gimprc").read_text()
            # Keep native escaped strings verbatim; runtime compares g_strescape().
            actual = re.search(r'^\(prev-language "((?:[^"\\]|\\.)*)"\)$', rc, re.M)
            version = re.search(r'^\(config-version "([0-9.]+)"\)$', rc, re.M)
            registry_path = profile / "user/pluginrc"
            if not registry_path.is_file():
                # A host locale override uses a private, environment-keyed
                # registry instead of the selected user registry.
                registries = list((profile / "cache/glims-pluginrc-environments").glob("*/pluginrc"))
                if len(registries) != 1 or not registries[0].is_file() or registries[0].is_symlink():
                    raise RuntimeError(f"{name}: expected exactly one generated command registry")
                registry_path = registries[0]
            registry = registry_path.read_bytes()
            if not actual or not version or b'(plug-in-def "${gimp_plug_in_dir}/' not in registry:
                raise RuntimeError(f"Engine did not write a relocatable startup registry and identity for {name}")
            if language and actual[1] != language:
                raise RuntimeError(f"Requested language {language} resolved to {actual[1]}")
            registry = registry.replace(contents.as_uri().encode(), b"@GLIMS_BUNDLE_URI@")
            if os.fsencode(contents) in registry or os.fsencode(work) in registry or work.as_uri().encode() in registry:
                raise RuntimeError("Startup registry contains a temporary build path")
            print(f"{name}: {result.stdout.strip()}", flush=True)
            return version[1], actual[1], registry

        def write_seed(target, version, language, registry, environment=None):
            target.mkdir(parents=True)
            (target / "identity").write_text(f"{version}\n{language}\n")
            (target / "pluginrc").write_bytes(registry)
            if environment is not None:
                (target / "environment").write_text(locale_environment_fingerprint(environment) + "\n")
            for item in target.iterdir():
                item.chmod(0o644)

        version, host_language, registry = capture("host")
        write_seed(destination, version, host_language, registry, os.environ)
        if any(key in os.environ for key in locale_environment_keys(os.environ)):
            clean_version, clean_language, clean_registry = capture("host-clean", clean_locale=True)
            if clean_version != version or clean_language != host_language:
                raise RuntimeError("Engine identity changed while preparing the clean host registry")
            digest = hashlib.sha256(clean_language.encode('utf-8')).hexdigest()
            write_seed(destination / "localized" / digest, version, clean_language, clean_registry)
        # These are exact environment pairs for the packager's complete macOS
        # preferred-language list. Other environments still discover natively.
        for code, locale in OVERRIDE_SEEDS:
            for launch_defaults in (False, True):
                environment = {'LANGUAGE': code, 'LC_ALL': locale}
                if launch_defaults:
                    # LaunchServices on macOS can add these two variables even
                    # when the launching process supplied neither one.
                    environment.update(LANG='C.UTF-8', LC_CTYPE='C.UTF-8')
                name = f'override-{code}' + ('-launch' if launch_defaults else '')
                override_version, actual, registry = capture(name, locale_override=environment)
                if override_version != version or actual != host_language:
                    raise RuntimeError(f"Engine identity changed while preparing {name}")
                key = override_seed_key(actual, environment)
                write_seed(destination / "overrides" / key, version, actual, registry, environment)
        for language in LOCALIZED_SEEDS:
            if language == host_language:
                continue
            local_version, actual, registry = capture(language, language)
            if local_version != version:
                raise RuntimeError(f"Engine version changed while preparing {language}")
            digest = hashlib.sha256(actual.encode('utf-8')).hexdigest()
            write_seed(destination / "localized" / digest, version, actual, registry)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: prepare-engine-startup.py APP")
    prepare(sys.argv[1])
