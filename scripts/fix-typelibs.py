#!/usr/bin/env python3
"""Repair macOS typelibs that point at libraries outside the engine install.

GIMP 3.0.8 to 3.2.4 install GObject-introspection typelibs whose
shared-library paths name the dependency prefix instead of the engine's own
lib directory, so Python plug-ins cannot load libgimp (seen at 3.0.8 and
3.2.0; at 3.0.8 the babl and GEGL typelibs too). Upstream fixed this in
GIMP 3.2.6 (commit 481bf7a998, "libgimp: Fix installed .typelib on macOS
builds"). This is a packaging workaround on the install tree only; the GIMP
sources stay untouched (AGENTS.md, zero-patch rule).

For every .gir in INSTALL/share/gir-1.0 whose shared-library entries name a
file that does not exist while INSTALL/lib has a library of the same name,
the entries are rewritten and the typelib is recompiled with g-ir-compiler.
Typelibs that already resolve are left alone, so this is a no-op on fixed
releases.

Usage: python3 -I fix-typelibs.py INSTALL_DIR PREFIX_DIR
Prints one line per repaired typelib.
"""
import os
import re
import subprocess
import sys
import tempfile

SHARED_LIBRARY = re.compile(r'shared-library="([^"]*)"')


def main():
    if len(sys.argv) != 3:
        print("usage: fix-typelibs.py INSTALL_DIR PREFIX_DIR", file=sys.stderr)
        return 2
    install, prefix = (os.path.abspath(p) for p in sys.argv[1:])
    gir_dir = os.path.join(install, "share", "gir-1.0")
    typelib_dir = os.path.join(install, "lib", "girepository-1.0")
    lib_dir = os.path.join(install, "lib")
    if not os.path.isdir(gir_dir):
        return 0

    for name in sorted(os.listdir(gir_dir)):
        if not name.endswith(".gir"):
            continue
        path = os.path.join(gir_dir, name)
        with open(path, encoding="utf-8") as handle:
            text = handle.read()

        changed = []

        def repair(match):
            entries = []
            for entry in match.group(1).split(","):
                local = os.path.join(lib_dir, os.path.basename(entry))
                if os.path.isabs(entry) and not os.path.exists(entry) and os.path.exists(local):
                    changed.append(entry)
                    entries.append(local)
                else:
                    entries.append(entry)
            return 'shared-library="%s"' % ",".join(entries)

        repaired = SHARED_LIBRARY.sub(repair, text)
        if not changed:
            continue

        typelib = os.path.join(typelib_dir, name[: -len(".gir")] + ".typelib")
        with tempfile.TemporaryDirectory() as scratch:
            fixed_gir = os.path.join(scratch, name)
            with open(fixed_gir, "w", encoding="utf-8") as handle:
                handle.write(repaired)
            subprocess.run(
                ["g-ir-compiler",
                 "--includedir", gir_dir,
                 "--includedir", os.path.join(prefix, "share", "gir-1.0"),
                 "--output", typelib, fixed_gir],
                check=True)
        print(f"repaired {os.path.basename(typelib)}: {len(changed)} library path(s) now point into {lib_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
