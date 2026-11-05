#!/usr/bin/env python3
"""Diff the GIMP functions the adapter calls between two engine versions.

The adapter (Engine/) depends on GIMP's internal app/ API, which has no
stability promise (docs/plan.md, "Engine update model"). This lists every
GIMP function the compiled adapter objects reference (from `nm -u`), finds
each one's prototype in the headers of two engine source trees, and reports
functions that disappeared or whose prototype changed. Run it before
building the adapter against a new engine: a reported change is a compile
error or, worse, a silent behavior change to look at.

It also compares the members of every GIMP struct the adapter names (for
example GimpProgressInterface, whose slots the adapter fills, or
GimpPlugInProcedure, whose fields it reads): a member that disappeared and
whose name the adapter uses is reported as a break.

Not covered (the adapter's startup checks and the conformance tests are):
macros, enum values, member types, GObject signals and properties.

Usage: python3 -I interface-diff.py OBJECT_DIR OLD_SOURCE_DIR NEW_SOURCE_DIR
  OBJECT_DIR   _engine/adapter/<ref>/obj (the adapter's compiled objects)
  *_SOURCE_DIR _engine/src/<ref>/gimp (an engine's GIMP source tree)
Exits 1 when a referenced function changed or vanished.
"""
import os
import re
import subprocess
import sys

ADAPTER_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Engine")

# GIMP's own symbols, as opposed to GLib, GEGL, babl, cairo or the system.
GIMP_PREFIXES = ("gimp_", "file_", "xcf_", "errors_", "language_", "sanity_")
HEADER_DIRS = ("app", "libgimpbase", "libgimpcolor", "libgimpconfig", "libgimpmath",
               "libgimpmodule", "libgimpthumb")
COMMENT = re.compile(r"/\*.*?\*/|//[^\n]*", re.S)
# G_DECLARE_*_TYPE (ModuleObjName, module_obj_name, ...) declares module_obj_name_get_type ().
DECLARE_TYPE = re.compile(r"G_DECLARE_(?:FINAL|DERIVABLE|INTERFACE)_TYPE\s*\(\s*\w+\s*,\s*(\w+)")
STRUCT = re.compile(r"struct\s+_(Gimp\w+)\s*\{(.*?)\}\s*;", re.S)
MEMBER = re.compile(r"\(\s*\*\s*(\w+)\s*\)\s*\(|(\w+)\s*(?:\[[^\]]*\])?\s*(?::\s*\d+)?\s*;")
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


def adapter_sources():
    texts = []
    for root, _, files in os.walk(ADAPTER_DIR):
        if "/tests" in root:
            continue
        for name in files:
            if name.endswith((".c", ".h")):
                with open(os.path.join(root, name), encoding="utf-8") as handle:
                    texts.append(COMMENT.sub(" ", handle.read()))
    return "\n".join(texts)


def struct_members(source_dir):
    """Member names of every `struct _GimpName { ... };` in the headers."""
    found = {}
    for top in HEADER_DIRS:
        for root, _, files in os.walk(os.path.join(source_dir, top)):
            for name in files:
                if not name.endswith(".h"):
                    continue
                with open(os.path.join(root, name), encoding="utf-8", errors="replace") as handle:
                    text = COMMENT.sub(" ", handle.read())
                for match in STRUCT.finditer(text):
                    body = re.sub(r"^\s*#.*$", " ", match.group(2), flags=re.M)
                    members = set()
                    for member in MEMBER.finditer(body):
                        members.add(member.group(1) or member.group(2))
                    found[match.group(1)] = members
    return found


def struct_changes(old_dir, new_dir):
    """Members of structs the adapter names that vanished and that the
    adapter's code mentions."""
    sources = adapter_sources()
    used_types = set(re.findall(r"\b(Gimp[A-Z]\w*)\b", sources))
    words = set(re.findall(r"\b\w+\b", sources))
    old, new = struct_members(old_dir), struct_members(new_dir)
    changes = []
    for name in sorted(used_types & set(old)):
        if name not in new:
            changes.append(f"struct   {name} no longer exists")
            continue
        gone = sorted(member for member in old[name] - new[name] if member in words)
        if gone:
            added = ", ".join(sorted(new[name] - old[name])) or "none"
            changes.append(f"struct   {name}: member(s) {', '.join(gone)} gone (added: {added})")
    return changes


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

    changed.extend(struct_changes(old_dir, new_dir))

    print(f"{len(functions)} GIMP functions referenced by the adapter; "
          f"{len(functions) - len(missing_old)} matched to a header prototype")
    if missing_old:
        print("not found in the old headers (defined in .c files or macros; not compared): "
              + ", ".join(missing_old))
    for line in changed:
        print(line)
    print("no referenced function or struct member changed" if not changed
          else f"{len(changed)} referenced function(s) or struct(s) changed")
    return 1 if changed else 0


if __name__ == "__main__":
    sys.exit(main())
