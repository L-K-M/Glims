#!/usr/bin/env python3
"""Derive the adapter's compile and link arguments from GIMP's own build.

The adapter (Engine/) is linked the way GIMP links gimp-console: the same
compile flags as gimp-console's sources, the same libraries, and every
gimp-console object file except main.c.o (the adapter replaces main()).
Nothing is hard-coded: the arguments come from `meson introspect --targets`
of the engine build, so an engine update brings its own flags.

Usage: python3 -I adapter-flags.py TARGETS_JSON BUILD_DIR INSTALL_DIR OUT_DIR

Writes OUT_DIR/compile.rsp, OUT_DIR/link.rsp and OUT_DIR/objects.rsp
(clang response files, one quoted argument per line).
"""
import json
import os
import shlex
import sys


def fail(message):
    print(f"adapter-flags: {message}", file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) != 5:
        fail("usage: adapter-flags.py TARGETS_JSON BUILD_DIR INSTALL_DIR OUT_DIR")
    targets_json, build_dir, install_dir, out_dir = sys.argv[1:]
    build_dir = os.path.abspath(build_dir)
    install_lib = os.path.join(os.path.abspath(install_dir), "lib")

    with open(targets_json) as handle:
        targets = json.load(handle)
    consoles = [t for t in targets if t["name"].startswith("gimp-console") and t["type"] == "executable"]
    if len(consoles) != 1:
        fail(f"expected one gimp-console target, found {len(consoles)}")
    console = consoles[0]

    compile_args, link_args = None, None
    for entry in console["target_sources"]:
        if entry.get("language") == "c":
            compile_args = entry["parameters"]
        elif "linker" in entry:
            link_args = entry["parameters"]
    if compile_args is None or link_args is None:
        fail("gimp-console has no C sources or no linker entry")

    def absolute(path):
        return path if os.path.isabs(path) else os.path.normpath(os.path.join(build_dir, path))

    compile_out = []
    for arg in compile_args:
        if arg.startswith("-I") and len(arg) > 2:
            compile_out.append("-I" + absolute(arg[2:]))
        elif arg in ("-MD",) or arg.startswith("-MQ") or arg.startswith("-MF"):
            continue
        else:
            compile_out.append(arg)

    # gimp-console links GIMP's base libraries from the build tree with
    # executable-relative rpaths; the adapter links the installed copies,
    # whose install names are absolute.
    link_out = []
    for arg in link_args:
        if arg.startswith("-Wl,-rpath,@loader_path"):
            continue
        if not arg.startswith("-") and arg.endswith(".dylib") and "/libgimp" in "/" + arg:
            installed = os.path.join(install_lib, os.path.basename(arg))
            if not os.path.exists(installed):
                fail(f"{installed} is missing; rebuild the engine")
            link_out.append(installed)
        elif not arg.startswith("-") and not os.path.isabs(arg):
            link_out.append(absolute(arg))
        else:
            link_out.append(arg)

    object_dir = os.path.join(build_dir, "app", os.path.basename(console["filename"][0]) + ".p")
    objects = sorted(
        os.path.join(object_dir, name)
        for name in os.listdir(object_dir)
        if name.endswith(".o") and name != "main.c.o"
    )
    if not objects:
        fail(f"no object files in {object_dir}")

    os.makedirs(out_dir, exist_ok=True)
    for name, args in (("compile.rsp", compile_out), ("link.rsp", link_out), ("objects.rsp", objects)):
        with open(os.path.join(out_dir, name), "w") as handle:
            handle.write("\n".join(shlex.quote(a) for a in args) + "\n")


if __name__ == "__main__":
    main()
