#!/usr/bin/env python3
"""Compare public library prototypes and .def exports between tags.
Usage: python3 -I libapi.py WORKDIR TAG_A TAG_B
"""
import importlib.util, os, sys, glob

spec = importlib.util.spec_from_file_location("decls", "/tmp/gimp-fork-research/skeptic-scripts/decls.py")
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)

LIBS = ["libgimp", "libgimpbase", "libgimpcolor", "libgimpconfig", "libgimpmath", "libgimpwidgets", "libgimpthumb", "libgimpmodule"]

def snap(root):
    funcs, defs = {}, {}
    for lib in LIBS:
        for h in glob.glob(os.path.join(root, lib, "*.h")):
            if "private" in os.path.basename(h):
                continue
            f, _, _ = d.parse_header(open(h, encoding="utf-8", errors="replace").read())
            for k, v in f.items():
                funcs[k] = (v, lib)
        for df in glob.glob(os.path.join(root, lib, "*.def")):
            syms = set()
            for l in open(df):
                l = l.strip()
                if l and l != "EXPORTS" and not l.startswith(";"):
                    syms.add(l.split()[0])
            defs[os.path.basename(df)] = syms
    return funcs, defs

w, a, b = sys.argv[1:4]
FA, DA = snap(os.path.join(w, a)); FB, DB = snap(os.path.join(w, b))
print(f"== {a} -> {b}")
for df in sorted(set(DA) | set(DB)):
    sa, sb = DA.get(df, set()), DB.get(df, set())
    print(f"  {df}: {len(sa)} -> {len(sb)}  removed={sorted(sa - sb)}  added={len(sb - sa)}")
exported = set().union(*DA.values())
chg = [k for k in FA if k in FB and FA[k][0] != FB[k][0] and k in exported]
gone = [k for k in FA if k not in FB and k in exported]
print("  exported prototypes changed:", [(k, FA[k][0], FB[k][0]) for k in chg])
print("  exported prototypes no longer declared in a public header:", gone)
