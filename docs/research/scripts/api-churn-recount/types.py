import os, re, sys
w = sys.argv[1]; tags = sys.argv[2:]
DIRS = ["app/core", "app/paint", "app/gegl", "app/pdb", "app/plug-in", "app/file", "app/xcf", "app/text", "app/vectors", "app/path", "app/operations", "app/config", "libgimpbase", "libgimpcolor", "libgimpconfig", "libgimpmath"]
R = re.compile(r"#\s*define\s+(GIMP_TYPE_\w+)\s")
def s(t):
    out = set()
    for d in DIRS:
        for dp, dn, fn in os.walk(os.path.join(w, t, d)):
            for f in fn:
                if f.endswith(".h"):
                    out |= set(R.findall(open(os.path.join(dp, f), encoding="utf-8", errors="replace").read()))
    return out
prev = None
for t in tags:
    cur = s(t)
    if prev is not None:
        print(f"{pt}->{t}: removed {sorted(prev-cur)} added {len(cur-prev)}")
    prev, pt = cur, t
