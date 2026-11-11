#!/usr/bin/env python3
"""Copy a built engine into Glims.app so the app runs without _engine/ or _deps/.

Usage: python3 -I bundle-engine.py APP INSTALL PREFIX ADAPTER SOURCES
  APP      the assembled Glims.app (scripts/build-app.sh)
  INSTALL  _engine/install/<ref>, the engine's install tree
  PREFIX   _deps/macports, the dependency prefix the engine was built against
  ADAPTER  _engine/adapter/<ref>/libglimsengine.dylib
  SOURCES  _engine/src/<ref>, the gimp, gegl and babl source trees (licenses)

Layout inside Contents/, modelled on GIMP's own macOS bundle
(build/macos/2_bundle-gimp-uni_base.py, read only):

  Frameworks/libglimsengine.dylib   the adapter, found by EngineLibrary
  MacOS/python3, MacOS/gimp-...      interpreters plug-ins start through PATH
  lib/                               every non-system dylib, flat, plus
                                     babl-0.1, gegl-0.4, gimp/3.0, typelibs,
                                     GTK runtime modules, Python.framework
  share/, etc/                       engine data and GTK/fontconfig data

Every Mach-O file gets @rpath install names and an rpath back to
Contents/lib, the typelibs are recompiled with @rpath library names, and
everything is signed ad hoc unless CODE_SIGN_IDENTITY (as in build-app.sh)
selects a real identity. The adapter finds this layout at run time and
points the engine and its plug-ins at it (Engine/engine.c, use_bundle).

Contents/Resources/Engine-Notices.txt lists every bundled component with
its version, license, homepage and license text: GIMP, GEGL and babl from
their source trees, and each MacPorts port that owns a copied file, with
the text from the port's installed docs or its source archive. A license
outside COMPATIBLE_LICENSES stops the bundling until it is reviewed
(AGENTS.md: confirm GPL compatibility before shipping a dependency).

Deliberately left out: GIMP's GTK modules and tool presets (the adapter
never loads them), engine translations (Glims is English-only so far),
gimp-console and other engine tools, headers, and Python's build tools.
"""
import base64
import hashlib
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import zipfile
import urllib.request

# Reviewed upstream v3.15.1 tag (07a36fde37aaab02f00e210c4c5035310b94213d)
# peels to this commit. LICENSE bytes are pinned separately; never use another
# release's text merely because a git-fetched port has no distfile archive.
AOM_LICENSE_SOURCES = {
    "3.15.1": ("44d0a57786f432d933ff64b653347c66f4d0fa1d",
               "4764a286d8b2faeaf42f4418e7d7a28d58fc8fd4d00a3d0a7f44b0a4099de7f2"),
}

class _AomNoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Reject before urllib drains an unbounded redirect response body.
        raise ValueError("upstream LICENSE redirect refused")


def _open_aom_license(url, *, timeout):
    return urllib.request.build_opener(_AomNoRedirect()).open(url, timeout=timeout)

PYTHON_VERSION = "3.13"
SYSTEM_PREFIXES = ("/usr/lib/", "/System/")
MACHO_MAGICS = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe"}

# MacPorts license names that may be combined with GPL-3.0-or-later code and
# shipped in the bundle. A port's license field lists all that apply; a
# {braced} group is a choice, acceptable when one member is.
#
# Reviewed 2026-11-05 for the GIMP 3.2.8 bundle: the GPL family as published
# (GPLv3 section 13 allows combining with AGPL-3; Ghostscript is used only
# by the PostScript plug-in); permissive MIT/BSD-style licenses (curl,
# fontconfig, JasPer-2, libepoxy's "permissive", X11, ISC, zlib, libpng,
# IJG, Expat, Libtiff); Apache-2 and OpenSSL 3 (Apache-2), compatible with
# GPLv3; FreeType (FTL), compatible with GPLv3; PSF for Python; MPL-2.
COMPATIBLE_LICENSES = {
    "GPL-2+", "GPL-3", "GPL-3+", "LGPL", "LGPL-2+", "LGPL-2.1", "LGPL-2.1+", "LGPL-3", "LGPL-3+",
    "AGPL-3", "AGPL-3+", "MIT", "X11", "BSD", "BSD-old", "ISC", "zlib", "libpng", "IJG",
    "Apache-2", "Apache-2+", "PSF", "Permissive", "permissive", "public-domain", "MPL-2", "MPL-2+",
    "Boost-1", "Unicode-3", "OpenSSL", "FTL", "FreeType", "Expat", "Libtiff", "Curl", "curl",
    "fontconfig", "JasPer-2", "W3C", "AFL-2.1", "CC0", "Zlib", "bzip2", "OFL-1.1",
    "CC-BY-SA-3", "CC-BY-SA-4", "GFDL-1.3+",
}
LICENSE_FILE = re.compile(r"^(copying|licen[cs]e|copyright|notice|copying\.lib|copying\.lesser)([._-].*)?$", re.I)

# Python packages plug-ins need; the rest of site-packages is build tooling.
PYTHON_PACKAGES = ("gi", "cairo")
PYTHON_STDLIB_SKIP = ("test", "idlelib", "tkinter", "turtledemo", "ensurepip",
                      "lib2to3", "config-" + PYTHON_VERSION + "-darwin", "__pycache__")


def run(*args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        raise SystemExit(f"{' '.join(args[:2])} ... failed:\n{result.stderr.strip()}")
    return result.stdout


def _has_license_body(text):
    """Whether notice text contains more than generated file headings."""
    return any(line.strip() and not line.startswith("--- ") for line in text.splitlines())


def _require_license_body(name, version, text):
    if not _has_license_body(text):
        raise SystemExit(f"{name} {version}: required license text unavailable. Restore matching "
                         "license documentation, source tree/archive or notice cache before bundling.")


def is_macho(path):
    if os.path.islink(path) or not os.path.isfile(path):
        return False
    with open(path, "rb") as handle:
        return handle.read(4) in MACHO_MAGICS


def copy_tree(source, destination, skip=()):
    """Copy a directory, keeping symlinks that stay inside it. Returns the
    source directory, to find the ports that own it."""
    skip = tuple(skip) + ("__pycache__",)

    def ignore(directory, names):
        return [name for name in names if name in skip]
    shutil.copytree(source, destination, symlinks=True, ignore=ignore, dirs_exist_ok=True)
    return source


def sample_files(directory, count=24):
    """Up to `count` regular files from a tree, spread over its folders."""
    found = []
    for root, _, files in os.walk(directory):
        regular = [os.path.join(root, f) for f in sorted(files) if not os.path.islink(os.path.join(root, f))]
        found += regular[:3]
        if len(found) >= count:
            break
    return found[:count]


def own_id(path):
    out = run("otool", "-D", path).splitlines()
    return out[1].strip() if len(out) > 1 else None


def linked_libraries(path):
    """Non-system install names a Mach-O file loads (LC_LOAD_*DYLIB); for a
    dylib, otool -L also lists its own name, which is left out."""
    identity = own_id(path)
    names = []
    for line in run("otool", "-L", path).splitlines()[1:]:
        name = line.strip().split(" (compatibility")[0]
        if name and name != identity and not name.startswith(SYSTEM_PREFIXES):
            names.append(name)
    return names


def rpaths(path):
    found, lines = [], run("otool", "-l", path).splitlines()
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            match = re.search(r"path (.*) \(offset", lines[index + 2])
            if match:
                found.append(match.group(1))
    return found


class Bundler:
    def __init__(self, app, install, prefix, adapter, sources):
        self.contents = os.path.join(app, "Contents")
        self.lib = os.path.join(self.contents, "lib")
        self.install = os.path.realpath(install)
        self.prefix = os.path.realpath(prefix)
        self.adapter = adapter
        self.framework = os.path.join(self.prefix, "Library/Frameworks/Python.framework/Versions", PYTHON_VERSION)
        self.bundled_framework = os.path.join(self.lib, "Python.framework/Versions", PYTHON_VERSION)
        self.sources = sources
        # Files and trees copied from the dependency prefix, to name their
        # ports. Every file needs an owner; a tree needs one owned file
        # (generated caches inside it belong to no port).
        self.from_prefix = set()
        self.prefix_trees = set()

    def path(self, *parts):
        return os.path.join(self.contents, *parts)

    # ---- Copying -----------------------------------------------------------

    def copy_engine(self):
        install = self.install
        os.makedirs(self.lib, exist_ok=True)
        for name in os.listdir(os.path.join(install, "lib")):
            source = os.path.join(install, "lib", name)
            if name.endswith(".dylib"):
                shutil.copy2(source, os.path.join(self.lib, name), follow_symlinks=False)
        for name in ("babl-0.1", "gegl-0.4"):
            copy_tree(os.path.join(install, "lib", name), os.path.join(self.lib, name))
        for name in ("plug-ins", "extensions", "interpreters", "environ"):
            source = os.path.join(install, "lib/gimp/3.0", name)
            if os.path.isdir(source):
                copy_tree(source, os.path.join(self.lib, "gimp/3.0", name))
        copy_tree(os.path.join(install, "share/gimp/3.0"), self.path("share/gimp/3.0"), skip=("tool-presets",))
        copy_tree(os.path.join(install, "etc/gimp/3.0"), self.path("etc/gimp/3.0"))
        # No engine translations, but plug-ins complain when the catalog
        # folder they are pointed at (GIMP3_LOCALEDIR) is missing.
        os.makedirs(self.path("share/locale"), exist_ok=True)

        os.makedirs(self.path("Frameworks"), exist_ok=True)
        shutil.copy2(self.adapter, self.path("Frameworks/libglimsengine.dylib"))
        os.makedirs(self.path("MacOS"), exist_ok=True)
        for name in os.listdir(os.path.join(install, "bin")):
            if name.startswith("gimp-script-fu-interpreter"):
                shutil.copy2(os.path.join(install, "bin", name), self.path("MacOS", name), follow_symlinks=False)

        # Python plug-ins resolve "python3" through PATH (Contents/MacOS
        # first); GIMP's installed file names the dependency prefix.
        with open(os.path.join(self.lib, "gimp/3.0/interpreters/pygimp.interp"), "w") as handle:
            handle.write("python=python3\npython3=python3\n/usr/bin/python=python3\n"
                         "/usr/bin/python3=python3\n:Python:E::py::python3:\n")
        # A relocatable GIMP build installs this; without it Python writes
        # bytecode caches into the bundle and breaks its signature.
        with open(os.path.join(self.lib, "gimp/3.0/environ/pygimp.env"), "w") as handle:
            handle.write("PYTHONDONTWRITEBYTECODE=1\n")

    def copy_runtime_data(self):
        prefix = self.prefix
        share = os.path.join(prefix, "share")
        for name in ("glib-2.0/schemas", "icons/Adwaita", "icons/hicolor", "themes/Mac", "mime",
                     "mypaint-data", "poppler", "libthai", "ghostscript", "libwmf"):
            source = os.path.join(share, name)
            if os.path.isdir(source):
                self.prefix_trees.add(copy_tree(source, self.path("share", name)))

        # GTK and GLib loadable modules, with their caches made relative.
        for name in ("gdk-pixbuf-2.0/2.10.0/loaders", "gtk-3.0/3.0.0/immodules",
                     "gtk-3.0/3.0.0/printbackends", "gio/modules"):
            source = os.path.join(prefix, "lib", name)
            if os.path.isdir(source):
                self.prefix_trees.add(copy_tree(source, os.path.join(self.lib, name)))
        cache = os.path.join(prefix, "lib/gdk-pixbuf-2.0/2.10.0/loaders.cache")
        if os.path.isfile(cache):
            with open(cache) as handle:
                text = handle.read().replace(os.path.join(prefix, "lib") + "/", "@GLIMS_LIB@/")
            # gdk-pixbuf needs absolute module paths; the adapter writes the
            # cache with Contents/lib in place of the placeholder when it
            # starts (Engine/engine.c, engine_paths).
            with open(os.path.join(self.lib, "gdk-pixbuf-2.0/2.10.0/loaders.cache.in"), "w") as handle:
                handle.write(text)

        # fontconfig: the system font folders, caches in the app's cache
        # folder (XDG_CACHE_HOME, set by the adapter), no MacPorts paths.
        fonts = self.path("etc/fonts")
        self.from_prefix.add(os.path.join(prefix, "etc/fonts/fonts.conf"))
        copy_tree(os.path.join(prefix, "etc/fonts/conf.d"), os.path.join(fonts, "conf.d"))
        for name in os.listdir(os.path.join(fonts, "conf.d")):
            link = os.path.join(fonts, "conf.d", name)
            if os.path.islink(link):
                target = os.path.realpath(os.path.join(prefix, "etc/fonts/conf.d", name))
                os.unlink(link)
                shutil.copy2(target, link)
        with open(os.path.join(prefix, "etc/fonts/fonts.conf")) as handle:
            conf = handle.read()
        conf = re.sub(r"<dir>[^<]*" + re.escape(prefix) + r"[^<]*</dir>", "", conf)
        conf = re.sub(r"<cachedir>[^<]*" + re.escape(prefix) + r"[^<]*</cachedir>", "", conf)
        if prefix in conf:
            raise SystemExit("fonts.conf still names the dependency prefix")
        with open(os.path.join(fonts, "fonts.conf"), "w") as handle:
            handle.write(conf)

    def copy_python(self):
        framework = self.framework
        bundled = self.bundled_framework
        os.makedirs(bundled, exist_ok=True)
        shutil.copy2(os.path.join(framework, "Python"), os.path.join(bundled, "Python"))
        self.from_prefix.add(os.path.realpath(os.path.join(framework, "Python")))
        stdlib = os.path.join(framework, "lib", "python" + PYTHON_VERSION)
        target = os.path.join(bundled, "lib", "python" + PYTHON_VERSION)
        copy_tree(stdlib, target, skip=PYTHON_STDLIB_SKIP + ("site-packages",))
        for package in PYTHON_PACKAGES:
            self.prefix_trees.add(copy_tree(os.path.join(stdlib, "site-packages", package),
                                            os.path.join(target, "site-packages", package)))
        # A framework build's python3 is a launcher that runs the
        # interpreter inside Resources/Python.app.
        copy_tree(os.path.join(framework, "Resources"), os.path.join(bundled, "Resources"))
        shutil.copy2(os.path.join(framework, "bin", "python" + PYTHON_VERSION), self.path("MacOS", "python3"))

    # ---- Libraries ---------------------------------------------------------

    def machos(self):
        found = []
        for top in ("lib", "MacOS", "Frameworks"):
            for root, _, files in os.walk(self.path(top)):
                for name in files:
                    path = os.path.join(root, name)
                    if path == self.path("MacOS", "Glims"):
                        continue
                    if is_macho(path):
                        found.append(path)
        return found

    def resolve(self, name, referrer):
        """Where an install name points on this machine."""
        if name.startswith("@loader_path/"):
            name = os.path.join(os.path.dirname(referrer), name[len("@loader_path/"):])
        if name.startswith("@rpath/"):
            tail = name[len("@rpath/"):]
            for base in rpaths(referrer):
                base = base.replace("@loader_path", os.path.dirname(referrer))
                candidate = os.path.join(base, tail)
                if os.path.exists(candidate):
                    return os.path.realpath(candidate)
            for base in (os.path.join(self.install, "lib"), os.path.join(self.prefix, "lib")):
                if os.path.exists(os.path.join(base, tail)):
                    return os.path.realpath(os.path.join(base, tail))
            return None
        return os.path.realpath(name) if os.path.exists(name) else None

    def destination(self, name, real):
        """Where a dependency goes in the bundle: under the name it is
        loaded by (often a symlink's name), flat in Contents/lib, or at
        its place inside the Python framework."""
        if real.startswith(os.path.realpath(self.framework) + "/"):
            return os.path.join(self.bundled_framework, os.path.relpath(real, os.path.realpath(self.framework)))
        return os.path.join(self.lib, os.path.basename(name))

    def collect_dependencies(self, extra_seeds):
        """Copy every non-system dylib the bundle's Mach-O files need."""
        pending = self.machos() + list(extra_seeds)
        seen, copied = set(), {}
        while pending:
            path = pending.pop()
            if path in seen:
                continue
            seen.add(path)
            for name in linked_libraries(path):
                real = self.resolve(name, path)
                if real is None:
                    raise SystemExit(f"{path}: cannot find {name}")
                if not (real.startswith(self.install + "/") or real.startswith(self.prefix + "/")):
                    raise SystemExit(f"{path}: {name} is outside the engine and the dependency prefix")
                target = self.destination(name, real)
                if real.startswith(self.prefix + "/"):
                    self.from_prefix.add(real)
                if not os.path.exists(target):
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    shutil.copy2(real, target)
                    os.chmod(target, os.stat(target).st_mode | stat.S_IWUSR)
                    copied[os.path.basename(target)] = real
                pending.append(target)
        return copied

    def rpath_for(self, path):
        relative = os.path.relpath(self.lib, os.path.dirname(path))
        return "@loader_path" if relative == "." else "@loader_path/" + relative

    def relink(self, path):
        """@rpath install names and one rpath to Contents/lib."""
        args = []
        identity = own_id(path)
        if identity:
            if path.startswith(self.bundled_framework + "/"):
                args += ["-id", "@rpath/" + os.path.relpath(path, self.lib)]
            else:
                args += ["-id", "@rpath/" + os.path.basename(path)]
        for name in linked_libraries(path):
            real = self.resolve(name, path)
            target = self.destination(name, real) if real else None
            if target and target.startswith(self.bundled_framework + "/"):
                new = "@rpath/" + os.path.relpath(target, self.lib)
            else:
                new = "@rpath/" + os.path.basename(name)
            if new != name:
                args += ["-change", name, new]
        wanted = self.rpath_for(path)
        existing = rpaths(path)
        for old in existing:
            if old != wanted:
                args += ["-delete_rpath", old]
        if wanted not in existing:
            args += ["-add_rpath", wanted]
        if args:
            run("install_name_tool", *args, path)

    # ---- Typelibs ----------------------------------------------------------

    def typelibs(self):
        """Recompile the typelibs plug-ins need with @rpath library names."""
        gir_dirs = [os.path.join(self.install, "share/gir-1.0"), os.path.join(self.prefix, "share/gir-1.0")]
        target = os.path.join(self.lib, "girepository-1.0")
        os.makedirs(target, exist_ok=True)
        pending, done, libraries = ["Gimp-3.0", "GimpUi-3.0"], set(), set()
        compiler = os.path.join(self.prefix, "bin/g-ir-compiler")
        while pending:
            name = pending.pop()
            if name in done:
                continue
            done.add(name)
            gir = next((os.path.join(d, name + ".gir") for d in gir_dirs
                        if os.path.exists(os.path.join(d, name + ".gir"))), None)
            if gir is None:
                raise SystemExit(f"no {name}.gir for the typelibs")
            with open(gir, encoding="utf-8") as handle:
                text = handle.read()
            for include, version in re.findall(r'<include name="([^"]+)" version="([^"]+)"', text):
                pending.append(f"{include}-{version}")

            def relocate(match):
                names = []
                for library in match.group(1).split(","):
                    names.append("@rpath/" + os.path.basename(library))
                    libraries.add(os.path.basename(library))
                return 'shared-library="' + ",".join(names) + '"'
            text = re.sub(r'shared-library="([^"]*)"', relocate, text)
            scratch = os.path.join(target, name + ".gir")
            with open(scratch, "w", encoding="utf-8") as handle:
                handle.write(text)
            run(compiler, "--includedir", target, *sum([["--includedir", d] for d in gir_dirs], []),
                scratch, "-o", os.path.join(target, name + ".typelib"))
            os.unlink(scratch)
        return sorted(libraries), sorted(done)

    def typelib_seeds(self, libraries):
        """The libraries typelibs dlopen() must be in the bundle too."""
        seeds = []
        for name in libraries:
            for base in (os.path.join(self.install, "lib"), os.path.join(self.prefix, "lib")):
                candidate = os.path.join(base, name)
                if os.path.exists(candidate):
                    real = os.path.realpath(candidate)
                    if real.startswith(self.prefix + "/"):
                        self.from_prefix.add(real)
                    target = os.path.join(self.lib, name)
                    if not os.path.exists(target):
                        shutil.copy2(real, target)
                        os.chmod(target, os.stat(target).st_mode | stat.S_IWUSR)
                    seeds.append(target)
                    break
            else:
                raise SystemExit(f"typelibs name {name}, which is not in the engine or the prefix")
        return seeds


    # ---- Notices -------------------------------------------------------------

    def port_info(self):
        """Ports owning the copied files: name -> (version, license, homepage)."""
        port = os.path.join(self.prefix, "bin/port")

        def owners_of(files):
            owned, unowned = set(), []
            for start in range(0, len(files), 100):
                out = run(port, "provides", *files[start:start + 100])
                for line in out.splitlines():
                    match = re.match(r"(.*) is provided by: (\S+)$", line.strip())
                    if match:
                        owned.add(match.group(2))
                    elif "is not provided by" in line:
                        unowned.append(line.split(" is not provided")[0].strip())
            return owned, unowned

        owners, unowned = owners_of(sorted(self.from_prefix))
        for tree in sorted(self.prefix_trees):
            tree_owners, _ = owners_of(sample_files(tree))
            if not tree_owners:
                unowned.append(tree + "/")
            owners |= tree_owners
        if unowned:
            raise SystemExit("files not owned by any port, so their license is unknown:\n  " + "\n  ".join(unowned))
        info = {}
        out = run(port, "-q", "info", "--name", "--version", "--license", "--homepage", *sorted(owners))
        for block in out.split("--\n"):
            lines = [line.strip() for line in block.strip().splitlines()]
            if len(lines) >= 4:
                info[lines[0]] = (lines[1], lines[2], lines[3])
        return info

    @staticmethod
    def compatible(license_field):
        """True when every license (or one of each {choice}) is compatible."""
        for choice in re.findall(r"\{([^}]*)\}|(\S+)", license_field):
            options = (choice[0] or choice[1]).split()
            if not any(option in COMPATIBLE_LICENSES for option in options):
                return False
        return True

    def license_texts(self, name, version):
        """The port's license files, from its installed docs or its source
        archive (cached per version under _engine/cache/notices)."""
        if name == "aom":
            return self.aom_license_text(version)
        cache = os.path.join(os.path.dirname(self.install), "..", "cache", "notices", f"{name}-{version}.txt")
        cache = os.path.normpath(cache)
        if os.path.exists(cache):
            with open(cache, encoding="utf-8") as handle:
                cached = handle.read()
            if _has_license_body(cached):
                return cached

        texts = []
        docs = os.path.join(self.prefix, "share/doc", name)
        if os.path.isdir(docs):
            for entry in sorted(os.listdir(docs)):
                path = os.path.join(docs, entry)
                if LICENSE_FILE.match(entry) and os.path.isfile(path):
                    with open(path, encoding="utf-8", errors="replace") as handle:
                        text = handle.read()
                    if text.strip():
                        texts.append((entry, text))
        if not texts:
            # Subports keep their archives under the parent's name; ask.
            out = run(os.path.join(self.prefix, "bin/port"), "-q", "distfiles", name)
            for archive in re.findall(r"^\[[^\]]*\] (\S+)$", out, re.M):
                if os.path.isfile(archive):
                    texts += [(entry, text) for entry, text in self.archive_licenses(archive) if text.strip()]
                if texts:
                    break
        result = "".join(f"--- {entry}\n\n{text.strip()}\n\n" for entry, text in texts)
        if _has_license_body(result):
            os.makedirs(os.path.dirname(cache), exist_ok=True)
            with open(cache, "w", encoding="utf-8") as handle:
                handle.write(result)
        return result

    def aom_license_text(self, version):
        """AOM's git fetch has no archive: require this release's verified text."""
        if version not in AOM_LICENSE_SOURCES:
            raise SystemExit(f"AOM {version}: add a reviewed upstream LICENSE commit/hash before bundling.")
        commit, digest = AOM_LICENSE_SOURCES[version]
        source_url = f"https://aomedia.googlesource.com/aom/+/{commit}/LICENSE"
        cache = os.path.normpath(os.path.join(os.path.dirname(self.install), "..", "cache", "notices",
                                             f"aom-{version}-{commit}.LICENSE"))
        data = None
        if os.path.isfile(cache):
            with open(cache, "rb") as handle:
                data = handle.read(65537)
        else:
            # Read committed Git content, not potentially patched working files.
            # port work may be empty after clean; inspect only that exact root
            # and its immediate children, never global source directories.
            try:
                work = run(os.path.join(self.prefix, "bin/port"), "-q", "work", "aom").strip()
            except SystemExit:
                work = ""
            candidates = []
            if work and os.path.isdir(work):
                candidates = [work] + [entry.path for entry in os.scandir(work) if entry.is_dir()]
            for candidate in candidates:
                if not os.path.exists(os.path.join(candidate, ".git")):
                    continue
                try:
                    if run("git", "-C", candidate, "rev-parse", "HEAD").strip() != commit:
                        continue
                    data = run("git", "-C", candidate, "show", f"{commit}:LICENSE").encode("utf-8")
                    break
                except SystemExit:
                    continue
            if data is None:
                # Small immutable primary-source fallback; no repository clone,
                # mutable tag lookup, or dependency rebuild during bundling.
                try:
                    with _open_aom_license(source_url + "?format=TEXT", timeout=15) as response:
                        if response.geturl() != source_url + "?format=TEXT":
                            raise ValueError("unexpected upstream redirect")
                        payload = response.read(65537)
                    if len(payload) > 65536:
                        raise ValueError("upstream LICENSE response is too large")
                    data = base64.b64decode(payload, validate=True)
                except (OSError, ValueError) as exc:
                    raise SystemExit(f"AOM {version}: required LICENSE unavailable. Restore the matching MacPorts "
                                     f"git worktree or obtain {source_url} (SHA-256 {digest}): {exc}") from exc
        if not data or len(data) > 65536 or hashlib.sha256(data).hexdigest() != digest:
            raise SystemExit(f"AOM {version}: LICENSE does not match reviewed SHA-256 {digest}; "
                             f"check the Git source or remove the invalid notice cache {cache}.")
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise SystemExit(f"AOM {version}: verified LICENSE is not UTF-8.") from exc
        if not os.path.isfile(cache):
            os.makedirs(os.path.dirname(cache), exist_ok=True)
            with open(cache, "wb") as handle:
                handle.write(data)
        return (f"--- LICENSE\n\nAOM {version} upstream source: {source_url}\n"
                f"LICENSE SHA-256: {digest}\n\n{text}\n")

    @staticmethod
    def archive_licenses(archive):
        """License files within the top two levels of a source archive
        (symlinks followed, as REUSE projects link COPYING into LICENSES/),
        or else the files of a top-level LICENSES folder."""
        def wanted(name):
            parts = name.split("/")
            return len(parts) <= 3 and LICENSE_FILE.match(parts[-1]) is not None

        def in_licenses_folder(name):
            parts = name.split("/")
            return len(parts) == 3 and parts[1] in ("LICENSES", "licenses")

        try:
            if zipfile.is_zipfile(archive):
                with zipfile.ZipFile(archive) as zipped:
                    names = [n for n in zipped.namelist() if not n.endswith("/")]
                    chosen = [n for n in names if wanted(n)] or [n for n in names if in_licenses_folder(n)]
                    return [(n, zipped.read(n).decode("utf-8", "replace")) for n in chosen]
            if not tarfile.is_tarfile(archive):
                return []
            with tarfile.open(archive) as tarred:
                members = {m.name.rstrip("/"): m for m in tarred.getmembers()}
                chosen = [n for n, m in members.items() if wanted(n) and (m.isfile() or m.issym())]
                if not chosen:
                    chosen = [n for n, m in members.items() if in_licenses_folder(n) and m.isfile()]
                found = []
                for name in sorted(chosen):
                    member = members[name]
                    if member.issym():
                        target = os.path.normpath(os.path.join(os.path.dirname(name), member.linkname))
                        member = members.get(target)
                        if member is None or not member.isfile():
                            continue
                    found.append((name, tarred.extractfile(member).read().decode("utf-8", "replace")))
                return found
        except (OSError, tarfile.TarError, zipfile.BadZipFile, EOFError):
            return []

    def write_notices(self):
        sections, problems = [], []
        projects = {
            "gimp": ("GIMP", "GPL-3+ (application and plug-ins), LGPL-3+ (libgimp libraries)", "https://www.gimp.org/"),
            "gegl": ("GEGL", "LGPL-3+ (library), GPL-3+ (some operations)", "https://gegl.org/"),
            "babl": ("babl", "LGPL-3+", "https://gegl.org/babl/"),
        }
        for project, (title, license_field, homepage) in projects.items():
            root = os.path.join(self.sources, project)
            texts = []
            for entry in sorted(os.listdir(root)):
                if LICENSE_FILE.match(entry) and os.path.isfile(os.path.join(root, entry)):
                    with open(os.path.join(root, entry), encoding="utf-8", errors="replace") as handle:
                        texts.append(f"--- {entry}\n\n{handle.read().strip()}\n\n")
            version = run("git", "-C", root, "describe", "--tags", "--always").strip()
            text = "".join(texts)
            _require_license_body(title, version, text)
            sections.append((title, version, license_field, homepage, text))

        for name, (version, license_field, homepage) in sorted(self.port_info().items()):
            if not self.compatible(license_field):
                problems.append(f"{name} {version}: license \"{license_field}\" is not on the compatible list")
            texts = self.license_texts(name, version)
            _require_license_body(name, version, texts)
            sections.append((name, version, license_field, homepage, texts))
        if problems:
            raise SystemExit("review these licenses before bundling (COMPATIBLE_LICENSES):\n  " + "\n  ".join(problems))

        header = ("Glims bundles GIMP's engine (GIMP, GEGL, babl) and the libraries, data and\n"
                  "Python runtime it needs, built from unmodified upstream sources with MacPorts.\n"
                  "Each component below keeps its own license. Components under the GPL, LGPL\n"
                  "or AGPL come with the right to their complete corresponding source code.\n\n")
        index = "".join(f"  {name} {version} ({license_field})\n" for name, version, license_field, _, _ in sections)
        body = "".join(f"{'=' * 72}\n{name} {version}\nLicense: {license_field}\nHomepage: {homepage}\n\n{texts}"
                       for name, version, license_field, homepage, texts in sections)
        with open(self.path("Resources", "Engine-Notices.txt"), "w", encoding="utf-8") as handle:
            handle.write(header + "Components:\n" + index + "\n" + body)
        return len(sections)

    # ---- Checks and signing -------------------------------------------------

    def check_no_build_paths(self):
        leaks = []
        for path in self.machos():
            for name in linked_libraries(path) + rpaths(path):
                if name.startswith(("/Volumes", "/Users", self.install, self.prefix)):
                    leaks.append(f"{os.path.relpath(path, self.contents)}: {name}")
        if leaks:
            raise SystemExit("build paths left in the bundle:\n  " + "\n  ".join(leaks[:20]))

    def sign(self):
        """Inner code first: loose Mach-O files, then nested app bundles
        (Python.app) as bundles. CODE_SIGN_IDENTITY selects the identity,
        as for the app itself in build-app.sh; unset or empty keeps the
        ad hoc '-'."""
        identity = os.environ.get("CODE_SIGN_IDENTITY") or "-"
        for path in self.machos():
            run("codesign", "--force", "--sign", identity, path)
        for root, directories, _ in os.walk(self.lib):
            for name in directories:
                if name.endswith(".app"):
                    run("codesign", "--force", "--sign", identity, os.path.join(root, name))


def main():
    if len(sys.argv) != 6:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    bundler = Bundler(*sys.argv[1:])
    bundler.copy_engine()
    bundler.copy_runtime_data()
    bundler.copy_python()
    libraries, typelibs = bundler.typelibs()
    seeds = bundler.typelib_seeds(libraries)
    copied = bundler.collect_dependencies(seeds)
    for path in bundler.machos():
        bundler.relink(path)
    bundler.check_no_build_paths()
    components = bundler.write_notices()
    bundler.sign()
    print(f"-- {len(copied)} dependency libraries, {len(typelibs)} typelibs, "
          f"{components} components in Engine-Notices.txt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
