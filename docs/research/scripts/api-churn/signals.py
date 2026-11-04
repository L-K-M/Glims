#!/usr/bin/env python3
"""Signal/property signature diff across tags. usage: python3 -I signals.py WORKDIR T1:T2 ..."""
import os, re, sys, json
sys.path.insert(0, "/tmp/gimp-fork-research/apichurn-scripts")
from snapshot import ENGINE_DIRS, UI_DIRS, walk, read, strip_comments, STRING_RE

W = sys.argv[1]


def balanced(s, i):
    depth = 0
    j = i
    while j < len(s):
        if s[j] == "(":
            depth += 1
        elif s[j] == ")":
            depth -= 1
            if depth == 0:
                return s[i + 1:j]
        j += 1
    return s[i + 1:]


def topsplit(s):
    out, d, cur = [], 0, ""
    for ch in s:
        if ch == "(":
            d += 1
        elif ch == ")":
            d -= 1
        if ch == "," and d == 0:
            out.append(cur.strip()); cur = ""
        else:
            cur += ch
    out.append(cur.strip())
    return [re.sub(r"\s+", " ", x) for x in out]


def snap(t):
    root = os.path.join(W, t)
    sigs, props = {}, {}
    for rel in walk(root, ENGINE_DIRS, {".c"}):
        src = strip_comments(read(os.path.join(root, rel)))
        cls = os.path.basename(rel)[:-2]
        if cls.endswith("-cmds"):
            continue
        for m in re.finditer(r"\bg_signal_new\s*\(", src):
            args = topsplit(balanced(src, m.end() - 1))
            name = re.sub(r'^I_\s*\(|"|\)$', "", args[0]).strip('"')
            rest = args[7:] if len(args) > 7 else args
            sigs[(cls, name)] = {"marshal": args[6] if len(args) > 6 else "", "ret_types": rest}
        for m in re.finditer(r"\b(GIMP_CONFIG_PROP_\w+)\s*\(", src):
            args = topsplit(balanced(src, m.end() - 1))
            if len(args) > 2 and args[2].startswith('"'):
                props[(cls, args[2].strip('"'))] = m.group(1)
        for m in re.finditer(r"\b(g_param_spec_\w+|gimp_param_spec_\w+)\s*\(\s*\"([\w-]+)\"", src):
            props.setdefault((cls, m.group(2)), m.group(1))
    ui_strings = set()
    for rel in walk(root, UI_DIRS, {".c", ".h"}):
        for m in STRING_RE.finditer(strip_comments(read(os.path.join(root, rel)))):
            ui_strings.add(m.group(0)[1:-1])
    return sigs, props, ui_strings


cache = {}
for pair in sys.argv[2:]:
    a, b = pair.split(":")
    for t in (a, b):
        if t not in cache:
            cache[t] = snap(t)
    sa, pa, ua = cache[a]
    sb, pb, ub = cache[b]
    sig_changed = [(k, sa[k]["ret_types"], sb[k]["ret_types"]) for k in sa if k in sb and sa[k]["ret_types"] != sb[k]["ret_types"]]
    sig_removed = [k for k in sa if k not in sb]
    sig_added = [k for k in sb if k not in sa]
    prop_type = [(k, pa[k], pb[k]) for k in pa if k in pb and pa[k] != pb[k]]
    prop_removed = [k for k in pa if k not in pb]
    ui_hit = lambda k: k[1] in ua
    print(f"== {a}->{b}: signals {len(sa)}->{len(sb)} removed={len(sig_removed)} (ui:{sum(map(ui_hit, sig_removed))}) "
          f"added={len(sig_added)} sig-changed={len(sig_changed)} (ui:{sum(ui_hit(k) for k,_,_ in sig_changed)}) | "
          f"props {len(pa)}->{len(pb)} removed={len(prop_removed)} (ui:{sum(map(ui_hit, prop_removed))}) type-changed={len(prop_type)} (ui:{sum(ui_hit(k) for k,_,_ in prop_type)})")
    for k, o, n in sig_changed:
        print("   SIGCHG", k, "ui" if ui_hit(k) else "-", o, "->", n)
    for k in sig_removed:
        print("   SIGREM", k, "ui" if ui_hit(k) else "-")
    for k in sig_added:
        print("   SIGADD", k, "ui" if k[1] in ub else "-")
    for k in prop_removed:
        if ui_hit(k):
            print("   PROPREM(ui)", k)
    for k, o, n in prop_type:
        print("   PROPTYPE", k, "ui" if ui_hit(k) else "-", o, "->", n)
