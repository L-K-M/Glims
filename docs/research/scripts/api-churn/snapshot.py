#!/usr/bin/env python3
"""Build an API snapshot of GIMP's engine layers and UI references for one tag tree.

usage: python3 -I snapshot.py <tagdir> <out.json>
Only reads files as text; never executes anything from the tree.
"""
import json, os, re, sys
from collections import defaultdict, Counter

ENGINE_DIRS = ["app/core", "app/paint", "app/gegl", "app/pdb", "app/plug-in", "app/file",
               "app/file-data", "app/xcf", "app/text", "app/path", "app/vectors",
               "app/operations", "app/config",
               "libgimpbase", "libgimpcolor", "libgimpconfig", "libgimpmath"]
UI_DIRS = ["app/tools", "app/display", "app/actions", "app/dialogs", "app/widgets",
           "app/gui", "app/menus", "app/propgui"]
PUBLIC_DIRS = ["libgimp"]

C_KEYWORDS = {"if", "for", "while", "switch", "return", "sizeof", "typedef", "struct",
              "enum", "union", "do", "else", "case", "default", "goto"}

COMMENT_RE = re.compile(r"/\*.*?\*/|//[^\n]*", re.S)
STRING_RE = re.compile(r'"(?:\\.|[^"\\\n])*"')
CHAR_RE = re.compile(r"'(?:\\.|[^'\\\n])+'")
IDENT_RE = re.compile(r"\b[A-Za-z_]\w*\b")


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def strip_comments(src):
    return COMMENT_RE.sub(" ", src)


def strip_preproc(src):
    out = []
    cont = False
    for line in src.split("\n"):
        s = line.lstrip()
        if cont or s.startswith("#"):
            cont = line.rstrip().endswith("\\")
            out.append("")
            continue
        out.append(line)
    return "\n".join(out)


ATTR_RE = re.compile(r"\b(G_GNUC_[A-Z_]+|GIMP_DEPRECATED_FOR|GIMP_DEPRECATED|G_DEPRECATED_FOR|G_DEPRECATED|"
                     r"GIMP_[A-Z]+_EXPORT|_GIMP_EXTERN|G_GNUC_BEGIN_IGNORE_DEPRECATIONS|"
                     r"G_GNUC_END_IGNORE_DEPRECATIONS|G_BEGIN_DECLS|G_END_DECLS|G_ANALYZER_NORETURN)\b(\s*\([^()]*\))?")


def norm_type(t):
    t = re.sub(r"\s+", " ", t).strip()
    t = re.sub(r"\s*\*\s*", "*", t)
    t = re.sub(r"\s*\[\s*", "[", t)
    t = re.sub(r"\s*\]\s*", "]", t)
    t = t.replace("*", " *").replace("  ", " ").strip()
    t = re.sub(r"\* \*", "**", t)
    return t


def split_params(p):
    parts, depth, cur = [], 0, ""
    for ch in p:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return [x.strip() for x in parts]


def param_type(p):
    p = p.strip()
    if p in ("void", "...", ""):
        return p
    if "(" in p:  # function pointer param
        p2 = re.sub(r"\(\s*\*\s*\w+\s*\)", "(*)", p)
        return norm_type(p2)
    # strip array dims
    arr = "".join(re.findall(r"\[[^\]]*\]", p))
    base = re.sub(r"\[[^\]]*\]", "", p).strip()
    toks = re.findall(r"[A-Za-z_]\w*|\*", base)
    idents = [t for t in toks if t != "*"]
    if len(idents) >= 2 and toks[-1] != "*" and idents[-1] not in ("int", "long", "short", "char", "double", "float", "unsigned", "signed"):
        toks = toks[:-1]
    return norm_type(" ".join(toks) + arr)


def parse_header_protos(src):
    s = strip_preproc(strip_comments(src))
    s = ATTR_RE.sub(" ", s)
    structs = {}
    enums = []
    # capture struct bodies
    for m in re.finditer(r"\bstruct\s+(_?\w+)\s*\{", s):
        name = m.group(1)
        i = m.end()
        depth = 1
        while i < len(s) and depth:
            if s[i] == "{":
                depth += 1
            elif s[i] == "}":
                depth -= 1
            i += 1
        body = s[m.end():i - 1]
        fields = []
        for decl in body.split(";"):
            d = re.sub(r"\s+", " ", decl).strip()
            if d:
                fields.append(d)
        structs[name.lstrip("_")] = fields
    for m in re.finditer(r"\benum\s*\w*\s*\{([^}]*)\}", s):
        for item in m.group(1).split(","):
            nm = item.split("=")[0].strip()
            if re.match(r"^[A-Za-z_]\w*$", nm):
                enums.append(nm)
    # remove all brace blocks
    out, depth = [], 0
    for ch in s:
        if ch == "{":
            depth += 1
            continue
        if ch == "}":
            depth -= 1
            continue
        if depth == 0:
            out.append(ch)
    s2 = "".join(out)
    protos = {}
    declared_types = []
    for stmt in s2.split(";"):
        st = re.sub(r"\s+", " ", stmt).strip()
        if not st:
            continue
        m = re.match(r"^G_DECLARE_(FINAL|DERIVABLE|INTERFACE)_TYPE\s*\(\s*(\w+)\s*,\s*(\w+)", st)
        if m:
            declared_types.append(m.group(2))
            protos[m.group(3) + "_get_type"] = {"ret": "GType", "params": ["void"]}
            continue
        if st.startswith("typedef") or st.startswith("extern"):
            continue
        m = re.match(r"^(.*?)\b([A-Za-z_]\w*)\s*\((.*)\)\s*$", st, re.S)
        if not m:
            continue
        ret, name, params = m.group(1).strip(), m.group(2), m.group(3)
        if name in C_KEYWORDS or not ret or re.match(r"^[A-Z0-9_]+$", name):
            continue
        if "(" in ret or "=" in ret:
            continue
        ptypes = [param_type(p) for p in split_params(params)]
        protos[name] = {"ret": norm_type(ret.replace("static", "").replace("inline", "")), "params": ptypes}
    return protos, structs, enums, declared_types


TYPE_CAST_RE = re.compile(r"G_TYPE_CHECK_INSTANCE_CAST\s*\(\s*\(?\s*\w+\s*\)?\s*,\s*(\w+)\s*,\s*(\w+)\s*\)")
SIGNAL_RE = re.compile(r"g_signal_new\s*\(\s*(?:I_\s*\()?\s*\"([\w-]+)\"")
PROP_RE = re.compile(r"(?:GIMP_CONFIG_PROP_\w+|GIMP_CONFIG_INSTALL_PROP_\w+)\s*\(\s*\w+\s*,\s*\w+\s*,\s*\"([\w-]+)\"|"
                     r"\b(?:g_param_spec_\w+|gimp_param_spec_\w+)\s*\(\s*\"([\w-]+)\"")


def walk(root, dirs, exts):
    for d in dirs:
        base = os.path.join(root, d)
        if not os.path.isdir(base):
            continue
        for dp, dn, fn in os.walk(base):
            rel = os.path.relpath(dp, root)
            if any(c == "tests" or c.startswith("test") for c in rel.split("/")):
                continue
            for f in sorted(fn):
                if os.path.splitext(f)[1] in exts:
                    yield os.path.relpath(os.path.join(dp, f), root)


def snapshot(root):
    funcs, structs, enums, types, signals, props = {}, {}, {}, {}, defaultdict(list), defaultdict(list)
    for rel in walk(root, ENGINE_DIRS, {".h"}):
        src = read(os.path.join(root, rel))
        p, st, en, dt = parse_header_protos(src)
        for k, v in p.items():
            v = dict(v, file=rel)
            funcs[k] = v
        for k, v in st.items():
            structs[k] = {"file": rel, "fields": v}
        for e in en:
            enums[e] = rel
        for m in TYPE_CAST_RE.finditer(strip_comments(src)):
            types[m.group(2)] = {"macro": m.group(1), "file": rel}
        for t in dt:
            types[t] = {"macro": None, "file": rel}
    for rel in walk(root, ENGINE_DIRS, {".c"}):
        src = strip_comments(read(os.path.join(root, rel)))
        cls = os.path.basename(rel)[:-2]
        for m in SIGNAL_RE.finditer(src):
            signals[m.group(1)].append(cls)
        for m in PROP_RE.finditer(src):
            props[m.group(1) or m.group(2)].append(cls)
    # UI references
    ui_ids = defaultdict(Counter)   # ident -> Counter(file -> count)
    ui_strings = defaultdict(Counter)
    ui_arrow = Counter()
    for rel in walk(root, UI_DIRS, {".c", ".h"}):
        raw = strip_comments(read(os.path.join(root, rel)))
        for m in STRING_RE.finditer(raw):
            v = m.group(0)[1:-1]
            if re.match(r"^[a-z][\w-]*$", v):
                ui_strings[v][rel] += 1
        code = STRING_RE.sub('""', raw)
        code = CHAR_RE.sub("''", code)
        for m in IDENT_RE.finditer(code):
            ui_ids[m.group(0)][rel] += 1
        for m in re.finditer(r"(?:->|\.)\s*([A-Za-z_]\w*)", code):
            ui_arrow[m.group(1)] += 1
    # public libgimp protos (exclude libgimpui sources per meson list)
    pub = {}
    for rel in walk(root, PUBLIC_DIRS, {".h"}):
        src = read(os.path.join(root, rel))
        p, st, en, dt = parse_header_protos(src)
        for k, v in p.items():
            pub[k] = dict(v, file=rel)
    return {
        "funcs": funcs, "structs": structs, "enums": enums, "types": types,
        "signals": signals, "props": props,
        "ui_ids": {k: dict(v) for k, v in ui_ids.items()},
        "ui_strings": {k: dict(v) for k, v in ui_strings.items()},
        "ui_arrow": dict(ui_arrow),
        "public": pub,
    }


if __name__ == "__main__":
    root, out = sys.argv[1], sys.argv[2]
    snap = snapshot(root)
    with open(out, "w") as f:
        json.dump(snap, f)
    print(root, "funcs", len(snap["funcs"]), "structs", len(snap["structs"]), "types", len(snap["types"]),
          "enums", len(snap["enums"]), "signals", len(snap["signals"]), "props", len(snap["props"]),
          "public", len(snap["public"]))
