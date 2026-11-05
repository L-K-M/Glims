#!/usr/bin/env python3
"""Diff the GIMP functions the adapter calls between two engine versions.

The adapter (Engine/) depends on GIMP's internal app/ API, which has no
stability promise (docs/plan.md, "Engine update model"). This lists every
GIMP function the compiled adapter objects reference (from `nm -u`), finds
each one's prototype in the headers of two engine source trees, and reports
functions that disappeared or whose prototype changed. Run it before
building the adapter against a new engine: a reported change is a compile
error or, worse, a silent behavior change to look at.

Not covered (the adapter's startup checks and the conformance tests are):
macros, enum values, struct layouts, GObject signals and properties.

Usage: python3 -I interface-diff.py OBJECT_DIR OLD_SOURCE_DIR NEW_SOURCE_DIR
  OBJECT_DIR   _engine/adapter/<ref>/obj (the adapter's compiled objects)
  *_SOURCE_DIR _engine/src/<ref>/gimp (an engine's GIMP source tree)
Exits 1 when a referenced function changed or vanished.
"""
import os
import re
import subprocess
import sys

# GIMP's own symbols, as opposed to GLib, GEGL, babl, cairo or the system.
GIMP_PREFIXES = ("gimp_", "file_", "xcf_", "errors_", "language_", "sanity_")
HEADER_DIRS = ("app", "libgimpbase", "libgimpcolor", "libgimpconfig", "libgimpmath",
               "libgimpmodule", "libgimpthumb")
COMMENT = re.compile(r"/\*.*?\*/|//[^\n]*", re.S)
# G_DECLARE_*_TYPE (ModuleObjName, module_obj_name, ...) declares module_obj_name_get_type ().
DECLARE_TYPE = re.compile(r"G_DECLARE_(?:FINAL|DERIVABLE|INTERFACE)_TYPE\s*\(\s*\w+\s*,\s*(\w+)")
DECLARATION = re.compile(r"([A-Za-z_][\w\s\*]*?[\s\*])([a-z_][a-z0-9_]*)\s*\(([^;{}()]*(?:\([^()]*\)[^;{}()]*)*)\)\s*(?:G_GNUC_\w+(?:\s*\([^)]*\))?\s*)*;")


def referenced_functions(object_dir):
    names = set()
    for name in sorted(os.listdir(object_dir)):
        if not name.endswith(".o"):
            continue
        out = subprocess.run(["nm", "-u", os.path.join(object_dir, name)],
                             capture_output=True, text=True, check=True).stdout
        for line in out.split():
            symbol = line.lstrip("_")
            if symbol.startswith(GIMP_PREFIXES):
                names.add(symbol)
    return names


def normalize(text):
    return re.sub(r"\s+", " ", text).replace(" *", "*").replace("* ", "*").strip()


def prototypes(source_dir):
    found = {}
    for top in HEADER_DIRS:
        for root, _, files in os.walk(os.path.join(source_dir, top)):
            if "/tests" in root:
                continue
            for name in files:
                if not name.endswith(".h"):
                    continue
                path = os.path.join(root, name)
                with open(path, encoding="utf-8", errors="replace") as handle:
                    text = COMMENT.sub(" ", handle.read())
                text = re.sub(r"^\s*#.*$", " ", text, flags=re.M)
                for match in DECLARE_TYPE.finditer(text):
                    found[match.group(1) + "_get_type"] = ("GType (void)", os.path.relpath(path, source_dir))
                for match in DECLARATION.finditer(text):
                    returns, function, params = match.groups()
                    found[function] = (normalize(returns) + " (" + normalize(params) + ")",
                                       os.path.relpath(path, source_dir))
    return found


def main():
    if len(sys.argv) != 4:
        print(__doc__.strip().splitlines()[-4], file=sys.stderr)
        return 2
    object_dir, old_dir, new_dir = sys.argv[1:]
    functions = referenced_functions(object_dir)
    old, new = prototypes(old_dir), prototypes(new_dir)

    changed, missing_old = [], []
    for function in sorted(functions):
        if function not in old:
            missing_old.append(function)
            continue
        if function not in new:
            changed.append(f"removed  {function}  (was {old[function][0]} in {old[function][1]})")
        elif old[function][0] != new[function][0]:
            changed.append(f"changed  {function}\n    old: {old[function][0]}\n    new: {new[function][0]}  ({new[function][1]})")

    print(f"{len(functions)} GIMP functions referenced by the adapter; "
          f"{len(functions) - len(missing_old)} matched to a header prototype")
    if missing_old:
        print("not found in the old headers (defined in .c files or macros; not compared): "
              + ", ".join(missing_old))
    for line in changed:
        print(line)
    print("no referenced function changed" if not changed else f"{len(changed)} referenced function(s) changed")
    return 1 if changed else 0


if __name__ == "__main__":
    sys.exit(main())
