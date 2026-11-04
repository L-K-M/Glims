import os, re, sys, glob
w = sys.argv[1]; pairs = sys.argv[2:]
ENGINE = ["app/core", "app/paint", "app/gegl", "app/pdb", "app/plug-in", "app/file", "app/xcf", "app/text", "app/vectors", "app/path", "app/operations", "app/config", "app/tools"]
R = re.compile(r"(GIMP_CONFIG_PROP_\w+|g_param_spec_\w+|gimp_param_spec_\w+)\s*\(\s*(?:\w+\s*,\s*\w+\s*,\s*)?\"([\w-]+)\"")
def snap(t):
    out = {}
    for d in ENGINE:
        for dp, dn, fn in os.walk(os.path.join(w, t, d)):
            for f in fn:
                if f.endswith(".c") and not dp.endswith("/pdb"):
                    txt = re.sub(r"/\*.*?\*/", " ", open(os.path.join(dp, f), encoding="utf-8", errors="replace").read(), flags=re.S)
                    base = f.replace("gimppath", "gimpvectors") if False else f
                    for m in R.finditer(txt):
                        out[(base, m.group(2))] = m.group(1)
    return out
for p in pairs:
    a, b = p.split(":")
    A, B = snap(a), snap(b)
    ch = [(k, A[k], B[k]) for k in A if k in B and A[k] != B[k]]
    print(f"== {a}->{b}: property type/kind changes with same file+name: {len(ch)}")
    for k, x, y in ch:
        print("   ", k, x, "->", y)
