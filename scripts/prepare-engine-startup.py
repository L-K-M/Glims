"""Query the finished bundle once and package its relocatable command registry.

Run after inner-code signing (which can change executable mtimes), before
outer app signing. No build paths, user preferences, or font caches are shipped.
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile


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
        environment = dict(os.environ)
        # Confine native libraries and subprocesses to this disposable home.
        for key, leaf in [("HOME", "home"), ("CFFIXED_USER_HOME", "home"),
                          ("XDG_CACHE_HOME", "cache"), ("XDG_CONFIG_HOME", "config"),
                          ("XDG_DATA_HOME", "data"), ("XDG_STATE_HOME", "state"),
                          ("GIMP3_DIRECTORY", "user"), ("TMPDIR", "tmp")]:
            (work / leaf).mkdir(exist_ok=True)
            environment[key] = str(work / leaf)
        result = subprocess.run([str(probe), str(contents / "Frameworks/libglimsengine.dylib"),
                                 str(work / "user"), str(work / "cache")],
                                env=environment, text=True, capture_output=True, timeout=180)
        if result.returncode:
            raise RuntimeError(f"Bundled engine startup failed:\n{result.stdout}\n{result.stderr}")
        rc = (work / "user/gimprc").read_text()
        # Keep native escaped strings verbatim; runtime compares g_strescape().
        language = re.search(r'^\(prev-language "((?:[^"\\]|\\.)*)"\)$', rc, re.M)
        version = re.search(r'^\(config-version "([0-9.]+)"\)$', rc, re.M)
        # Native registry blobs may contain binary icon data.
        registry = (work / "user/pluginrc").read_bytes()
        if not language or not version or b'(plug-in-def "${gimp_plug_in_dir}/' not in registry:
            raise RuntimeError("Engine did not write a relocatable startup registry and identity")
        registry = registry.replace(contents.as_uri().encode(), b"@GLIMS_BUNDLE_URI@")
        if os.fsencode(contents) in registry or os.fsencode(work) in registry or work.as_uri().encode() in registry:
            raise RuntimeError("Startup registry contains a temporary build path")
        destination.mkdir()
        (destination / "identity").write_text(f"{version[1]}\n{language[1]}\n")
        (destination / "pluginrc").write_bytes(registry)
        for path in destination.iterdir():
            path.chmod(0o644)
        print(result.stdout.strip())


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: prepare-engine-startup.py APP")
    prepare(sys.argv[1])
