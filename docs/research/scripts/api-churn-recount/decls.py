#!/usr/bin/env python3
"""Independent recount of GIMP engine-header API surface and churn.

Usage: python3 -I decls.py WORKDIR TAG_A TAG_B [--verbose]

WORKDIR/<TAG> are git-archive extracted trees (data only; nothing is executed).
"""
import os, re, sys, json, collections

ENGINE_DIRS = ["app/core", "app/paint", "app/gegl", "app/pdb", "app/plug-in",
               "app/file", "app/file-data", "app/xcf", "app/text", "app/vectors",
               "app/path", "app/operations", "app/config",
               "libgimpbase", "libgimpcolor", "libgimpconfig", "libgimpmath",
               "libgimpmodule", "libgimpthumb"]
UI_DIRS = ["app/actions", "app/dialogs", "app/display", "app/gui", "app/menus",
           "app/tools", "app/widgets", "app/propgui"]

def files_under(root, dirs, exts):
    out = []
    for d in dirs:
        p = os.path.join(root, d)
        if not os.path.isdir(p):
            continue
        for dp, dn, fn in os.walk(p):
            if "/tests" in dp[len(root):]:
                continue
            for f in fn:
                if f.endswith(exts):
                    out.append(os.path.join(dp, f))
    return sorted(out)

def strip_comments(s):
    s = re.sub(r"/\*.*?\*/", " ", s, flags=re.S)
    s = re.sub(r"//[^\n]*", " ", s)
    return s

def strip_pp(s):
    s = re.sub(r"\\\n", " ", s)
    return "\n".join(l for l in s.split("\n") if not l.lstrip().startswith("#"))

ATTR_RE = re.compile(r"\b(G_GNUC_\w+(\s*\([^)]*\))?|G_GNUC_CONST|GIMP_DEPRECATED\w*(\s*\([^)]*\))?|G_DEPRECATED\w*(\s*\([^)]*\))?|G_GNUC_WARN_UNUSED_RESULT|G_GNUC_MALLOC|G_GNUC_PRINTF\s*\([^)]*\)|G_BEGIN_DECLS|G_END_DECLS|extern|G_GNUC_NULL_TERMINATED|G_GNUC_INTERNAL|GIMP_WARN_UNUSED_RESULT)")

def norm_ws(s):
    s = re.sub(r"\s+", " ", s).strip()
    s = re.sub(r"\s*\*\s*", "*", s)
    s = s.replace("*", " *").replace("  ", " ")
    s = re.sub(r"\s*,\s*", ", ", s)
    return s.strip()

KW = {"const", "unsigned", "signed", "struct", "enum", "volatile", "long", "short"}

def norm_param(p):
    p = re.sub(r"\s+", " ", p).strip()
    if p in ("void", "...", ""):
        return p
    # function pointer param:  ret (*name) (args)
    p = re.sub(r"\(\s*\*\s*\w+\s*\)", "(*)", p)
    # arrays
    p = re.sub(r"\b\w+\s*(\[[^\]]*\])+\s*$", lambda m: re.sub(r"^\w+\s*", "", m.group(0)), p)
    toks = re.findall(r"[A-Za-z_]\w*|\*|\S", p)
    if "(*)" in p or "[" in p:
        return norm_ws(p)
    if len(toks) >= 2 and re.match(r"[A-Za-z_]\w*$", toks[-1]) and toks[-1] not in KW:
        # drop the parameter name
        idx = p.rfind(toks[-1])
        p = p[:idx]
    return norm_ws(p)

def split_top(s, sep=","):
    out, depth, cur = [], 0, []
    for ch in s:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == sep and depth == 0:
            out.append("".join(cur)); cur = []
        else:
            cur.append(ch)
    out.append("".join(cur))
    return out

def top_level_statements(s):
    """yield (statement_text, kind) for brace-depth-0 statements; struct/enum bodies are
    returned whole."""
    depth, cur = 0, []
    for ch in s:
        cur.append(ch)
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        elif ch == ";" and depth == 0:
            yield "".join(cur)
            cur = []

FUNC_RE = re.compile(r"^(?P<ret>.*?)\b(?P<name>[A-Za-z_]\w*)\s*\((?P<args>.*)\)\s*;$", re.S)

def parse_header(text):
    funcs, structs, enums = {}, {}, {}
    t = strip_pp(strip_comments(text))
    t = ATTR_RE.sub(" ", t)
    for st in top_level_statements(t):
        s = st.strip()
        if not s:
            continue
        if "{" in s:
            m = re.match(r"^(typedef\s+)?(struct|union)\s+(\w+)?\s*\{(.*)\}\s*(\w*)\s*;$", s, re.S)
            if m:
                name = m.group(3) or m.group(5)
                body = m.group(4)
                fields = []
                for f in body.split(";"):
                    f = re.sub(r"\s+", " ", f).strip()
                    if not f:
                        continue
                    # field name: last identifier, or (*name) for fn ptrs
                    fm = re.search(r"\(\s*\*\s*(\w+)\s*\)", f)
                    if fm:
                        fname = fm.group(1)
                    else:
                        parts = [x.strip() for x in f.split(",")]
                        # handle "gint a, b"
                        base = parts[0]
                        names = []
                        bm = re.search(r"(\w+)\s*(\[[^\]]*\]|:\s*\d+)*\s*$", base)
                        if bm:
                            names.append(bm.group(1))
                        for extra in parts[1:]:
                            em = re.search(r"(\w+)", extra)
                            if em:
                                names.append(em.group(1))
                        for n in names:
                            fields.append((n, norm_ws(f)))
                        continue
                    fields.append((fname, norm_ws(f)))
                structs[name] = fields
                continue
            m = re.match(r"^(typedef\s+)?enum\s*(\w+)?\s*\{(.*)\}\s*(\w*)\s*;$", s, re.S)
            if m:
                name = m.group(4) or m.group(2) or "<anon>"
                vals = []
                for v in split_top(m.group(3)):
                    v = re.sub(r"\s+", " ", v).strip()
                    v = re.sub(r"/\*<.*?>\*/", "", v).strip()
                    if v:
                        vm = re.match(r"(\w+)\s*(=\s*(.*))?$", v)
                        if vm:
                            vals.append((vm.group(1), (vm.group(3) or "").strip()))
                key = name
                if key == "<anon>":
                    key = "<anon>:" + (vals[0][0] if vals else "")
                enums[key] = vals
                continue
            continue
        if s.startswith("typedef"):
            continue
        m = FUNC_RE.match(s)
        if not m:
            continue
        name = m.group("name")
        ret = m.group("ret")
        if not ret.strip() or name.isupper() or name.startswith("G_DECLARE") or name.startswith("G_DEFINE"):
            continue
        if "(" in ret or "=" in ret:
            continue
        args = [norm_param(a) for a in split_top(m.group("args"))]
        funcs[name] = norm_ws(ret) + " (" + ", ".join(args) + ")"
    return funcs, structs, enums

DEFINE_RE = re.compile(r"^\s*#\s*define\s+(\w+)(\([^)]*\))?\s*(.*)$")

def parse_defines(text):
    t = strip_comments(text)
    t = re.sub(r"\\\n", " ", t)
    out = {}
    for l in t.split("\n"):
        m = DEFINE_RE.match(l)
        if m:
            name = m.group(1)
            if name.endswith("_H__") or name.endswith("_H_"):
                continue
            out[name] = ((m.group(2) or "") + " " + re.sub(r"\s+", " ", m.group(3))).strip()
    return out

SIG_RE = re.compile(r"g_signal_new\s*\(\s*(?:I_\()?\s*\"([\w-]+)\"\s*\)?(.*?)\)\s*;", re.S)
PROP_RE = re.compile(r"(?:GIMP_CONFIG_PROP_\w+|g_param_spec_\w+|gimp_param_spec_\w+|GIMP_PROP_\w+)\s*\(\s*(?:object_class\s*,\s*\w+\s*,\s*)?\"([\w-]+)\"")
OVERRIDE_RE = re.compile(r"g_object_class_override_property\s*\(\s*\w+\s*,\s*\w+\s*,\s*\"([\w-]+)\"")

def parse_c_signals_props(text):
    t = strip_comments(text)
    sigs = {}
    for m in SIG_RE.finditer(t):
        name = m.group(1)
        rest = re.sub(r"\s+", " ", m.group(2))
        # params after G_TYPE_xxx return, n_params ...
        parts = [p.strip() for p in split_top(rest)]
        # find n_params: first integer literal after the marshaller
        n = None; types = []
        for i, p in enumerate(parts):
            if re.fullmatch(r"\d+", p):
                n = int(p); types = parts[i + 1:]
                break
        sigs[name] = (n, tuple(types))
    props = set(PROP_RE.findall(t)) | set(OVERRIDE_RE.findall(t))
    return sigs, props

def snapshot(root):
    funcs, structs, enums, defines, where = {}, {}, {}, {}, {}
    for f in files_under(root, ENGINE_DIRS, (".h",)):
        rel = f[len(root) + 1:]
        txt = open(f, encoding="utf-8", errors="replace").read()
        fu, st, en = parse_header(txt)
        for k, v in fu.items():
            funcs[k] = v; where[k] = rel
        for k, v in st.items():
            structs[k] = v
        for k, v in en.items():
            enums[k] = v
        for k, v in parse_defines(txt).items():
            defines[k] = (v, rel)
    sigs, props = {}, {}
    for f in files_under(root, ENGINE_DIRS, (".c",)):
        rel = f[len(root) + 1:]
        txt = open(f, encoding="utf-8", errors="replace").read()
        s, p = parse_c_signals_props(txt)
        for k, v in s.items():
            sigs[rel + "::" + k] = v
        if p:
            props[rel] = sorted(p)
    return dict(funcs=funcs, where=where, structs=structs, enums=enums,
                defines=defines, sigs=sigs, props=props)

def ui_corpus(root):
    texts = {}
    for f in files_under(root, UI_DIRS, (".c", ".h")):
        texts[f[len(root) + 1:]] = strip_comments(open(f, encoding="utf-8", errors="replace").read())
    return texts

def count_refs(texts, names):
    pat = re.compile(r"\b(" + "|".join(re.escape(n) for n in sorted(names, key=len, reverse=True)) + r")\b") if names else None
    cnt = collections.Counter(); files = collections.defaultdict(set)
    if not pat:
        return cnt, files
    for rel, t in texts.items():
        for m in pat.finditer(t):
            cnt[m.group(1)] += 1; files[m.group(1)].add(rel)
    return cnt, files

def main():
    work, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
    verbose = "--verbose" in sys.argv
    A = snapshot(os.path.join(work, a)); B = snapshot(os.path.join(work, b))
    uiA = ui_corpus(os.path.join(work, a))
    # surface at A
    allnames = set(A["funcs"])
    cnt, files = count_refs(uiA, allnames)
    surface = {n for n in allnames if cnt[n] > 0}
    removed = sorted(n for n in A["funcs"] if n not in B["funcs"])
    added = sorted(n for n in B["funcs"] if n not in A["funcs"])
    changed = sorted(n for n in A["funcs"] if n in B["funcs"] and A["funcs"][n] != B["funcs"][n])
    print(f"== {a} -> {b}")
    print(f"engine funcs declared: {len(A['funcs'])} -> {len(B['funcs'])}; surface(A)={len(surface)} refs={sum(cnt[n] for n in surface)}")
    print(f"engine-wide removed={len(removed)} changed={len(changed)} added={len(added)}")
    s_rem = [n for n in removed if n in surface]
    s_chg = [n for n in changed if n in surface]
    print(f"SURFACE removed={len(s_rem)} changed={len(s_chg)} call-sites(A)={sum(cnt[n] for n in s_rem + s_chg)}")
    for n in s_rem:
        print(f"  REMOVED {n} refs={cnt[n]} files={len(files[n])}  [{A['where'][n]}]  {A['funcs'][n]}")
    for n in s_chg:
        print(f"  CHANGED {n} refs={cnt[n]} files={len(files[n])}  [{A['where'][n]}]\n     A: {A['funcs'][n]}\n     B: {B['funcs'][n]}")
    if verbose:
        print("  engine-wide removed:", removed)
        print("  engine-wide changed:", changed)
        print("  added:", added)
    # header moves for surface funcs
    moved = [n for n in A["funcs"] if n in B["where"] and A["where"][n] != B["where"][n]]
    hdr_moves = collections.Counter((A["where"][n], B["where"][n]) for n in moved)
    print(f"functions whose declaring header moved: {len(moved)} (surface: {len([n for n in moved if n in surface])}) in {len(hdr_moves)} header pairs")
    # structs
    uitext = "\n".join(uiA.values())
    st_changes = []
    for s, fa in A["structs"].items():
        fb = B["structs"].get(s)
        if fb is None:
            st_changes.append((s, "struct body gone (opaque/removed)", [])); continue
        na = dict(fa); nb = dict(fb)
        gone = [f for f in na if f not in nb]
        typ = [f for f in na if f in nb and na[f] != nb[f]]
        new = [f for f in nb if f not in na]
        order = [x for x, _ in fa if x in nb] != [x for x, _ in fb if x in na]
        if gone or typ or new or order:
            st_changes.append((s, f"gone={gone} type={typ} new={new} reorder={order}", gone + typ))
    print(f"struct changes (engine headers): {len(st_changes)}")
    for s, d, fl in st_changes:
        used_struct = re.search(r"\b" + re.escape(s.lstrip("_")) + r"\b", uitext) is not None
        hits = {f: len(re.findall(r"(->|\.)\s*" + re.escape(f) + r"\b", uitext)) for f in fl}
        if used_struct or any(hits.values()):
            print(f"  STRUCT {s} (type named in UI: {used_struct}) {d} ui-field-hits(gone/type)={hits}")
    # enums
    print("enum changes:")
    for e, va in A["enums"].items():
        vb = B["enums"].get(e)
        if vb is None:
            print(f"  ENUM {e} gone"); continue
        na = [x for x, _ in va]; nb = [x for x, _ in vb]
        gone = [x for x in na if x not in nb]
        new = [x for x in nb if x not in na]
        # positional shift: does any common value get a different implicit index?
        def idx(vals):
            d, i = {}, 0
            for n, v in vals:
                if v:
                    try:
                        i = int(v, 0)
                    except ValueError:
                        d[n] = v; i = None; continue
                d[n] = i
                i = i + 1 if isinstance(i, int) else None
            return d
        ia, ib = idx(va), idx(vb)
        shifted = [x for x in na if x in ib and ia.get(x) != ib.get(x)]
        if gone or new or shifted:
            used_gone = [x for x in gone if re.search(r"\b" + x + r"\b", uitext)]
            print(f"  ENUM {e}: gone={gone} (UI-used {used_gone}) new={new} shifted={len(shifted)} {shifted[:4]}")
    # defines
    dchg = []
    for d, (v, w) in A["defines"].items():
        if d not in B["defines"]:
            dchg.append((d, v, None, w))
        elif B["defines"][d][0] != v:
            dchg.append((d, v, B["defines"][d][0], w))
    used = [(d, va, vb, w) for d, va, vb, w in dchg if re.search(r"\b" + d + r"\b", uitext)]
    print(f"#define changes: {len(dchg)} total, {len(used)} used by UI:")
    for d, va, vb, w in used:
        print(f"  DEFINE {d} [{w}]: {va!r} -> {vb!r}")
    # signals
    print("signal changes:")
    for k, v in A["sigs"].items():
        if k not in B["sigs"]:
            print(f"  SIGNAL gone/moved {k}")
        elif B["sigs"][k] != v:
            print(f"  SIGNAL {k}: {v} -> {B['sigs'][k]}")
    for k in B["sigs"]:
        if k not in A["sigs"]:
            print(f"  SIGNAL new {k}")
    # properties
    print("property-name changes (per engine .c file):")
    for f, pa in A["props"].items():
        pb = set(B["props"].get(f, []))
        if f not in B["props"]:
            print(f"  PROPFILE gone {f} ({len(pa)} props)")
            continue
        gone = [p for p in pa if p not in pb]
        new = [p for p in pb if p not in set(pa)]
        if gone or new:
            used_gone = [p for p in gone if '"' + p + '"' in uitext]
            print(f"  PROPS {f}: gone={gone} (UI string-literal use {used_gone}) new={new}")
    for f in B["props"]:
        if f not in A["props"]:
            print(f"  PROPFILE new {f}: {B['props'][f][:12]}")

if __name__ == "__main__":
    main()
