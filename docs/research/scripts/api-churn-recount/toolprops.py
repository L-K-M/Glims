import importlib.util, os, sys, glob
spec = importlib.util.spec_from_file_location("decls", "/tmp/gimp-fork-research/skeptic-scripts/decls.py")
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
w = sys.argv[1]; tags = sys.argv[2:]
def props(t):
    out = {}
    for f in glob.glob(os.path.join(w, t, "app/tools/*options*.c")) + glob.glob(os.path.join(w, t, "app/paint/*options*.c")):
        _, p = d.parse_c_signals_props(open(f, encoding="utf-8", errors="replace").read())
        out[os.path.relpath(f, os.path.join(w, t))] = set(p)
    return out
prev = None
for t in tags:
    cur = props(t)
    tot = sum(len(v) for v in cur.values())
    if prev:
        add = sum(len(cur.get(k, set()) - prev.get(k, set())) for k in cur)
        rem = sum(len(prev[k] - cur.get(k, set())) for k in prev)
        det = [(k, sorted(cur.get(k,set()) - prev.get(k,set())), sorted(prev.get(k,set()) - cur.get(k,set()))) for k in sorted(set(cur)|set(prev)) if cur.get(k,set()) != prev.get(k,set())]
        print(f"{pt}->{t}: total {tot}, +{add} -{rem}")
        for k, a, r in det:
            print(f"   {k}: +{a} -{r}")
    else:
        print(f"{t}: total {tot} in {len(cur)} files")
    prev, pt = cur, t
