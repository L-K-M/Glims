#!/usr/bin/env python3
"""Per-commit engine-header prototype/struct churn. usage: python3 -I percommit.py OUTFILE"""
import subprocess, sys, json, re
sys.path.insert(0, "/tmp/gimp-fork-research/apichurn-scripts")
from snapshot import parse_header_protos

GIT = ["git", "-C", "/tmp/gimp-fork-research/full-apichurn.git"]
E = ["app/core", "app/paint", "app/gegl", "app/pdb", "app/plug-in", "app/file", "app/file-data", "app/xcf",
     "app/text", "app/path", "app/vectors", "app/operations", "app/config",
     "libgimpbase", "libgimpcolor", "libgimpconfig", "libgimpmath"]
UI = ["app/tools", "app/display", "app/actions", "app/dialogs", "app/widgets", "app/gui", "app/menus", "app/propgui"]
HSPEC = [f":(glob){d}/**/*.h" for d in E]
OUTD = "/tmp/gimp-fork-research/apichurn-out"
TAGS = ["GIMP_3_0_0", "GIMP_3_0_2", "GIMP_3_0_4", "GIMP_3_0_6", "GIMP_3_0_8", "GIMP_3_1_2", "GIMP_3_1_4",
        "GIMP_3_2_0", "GIMP_3_2_2", "GIMP_3_2_4", "GIMP_3_2_6", "GIMP_3_2_8", "master"]


def git(*a):
    return subprocess.run(GIT + list(a), capture_output=True, text=True, errors="replace").stdout


surface, focus, uirefs, struct_ui = set(), set(), {}, set()
for t in TAGS:
    s = json.load(open(f"{OUTD}/{t}.json"))
    for f in s["funcs"]:
        d = s["ui_ids"].get(f)
        if d:
            surface.add(f)
            uirefs[f] = max(uirefs.get(f, 0), sum(d.values()))
    for st in s["structs"]:
        if st in s["ui_ids"]:
            struct_ui.add(st)


def sig(v):
    return v["ret"] + " (" + ", ".join(v["params"]) + ")"


def branches_of(c):
    out = git("branch", "--contains", c, "--format=%(refname:short)").split()
    return ",".join(sorted(b for b in out if b in ("master", "gimp-3-0", "gimp-3-2")))


results = []
commits = git("rev-list", "--reverse", "master", "gimp-3-0", "gimp-3-2", "^GIMP_3_0_0", "--", *HSPEC).split()
for c in commits:
    ns = git("diff-tree", "-r", "-M", "--name-status", "--no-commit-id", c + "^", c, "--", *HSPEC)
    rem, chg, add, sfields, sopaque = [], [], [], [], []
    for line in ns.splitlines():
        parts = line.split("\t")
        st = parts[0]
        if st.startswith("R"):
            old, new = parts[1], parts[2]
        elif st == "A":
            old, new = None, parts[1]
        elif st == "D":
            old, new = parts[1], None
        else:
            old = new = parts[1]
        a = parse_header_protos(git("show", f"{c}^:{old}")) if old else ({}, {}, [], [])
        b = parse_header_protos(git("show", f"{c}:{new}")) if new else ({}, {}, [], [])
        pa, pb = a[0], b[0]
        for f in pa:
            if f not in pb:
                rem.append(f)
            elif sig(pa[f]) != sig(pb[f]):
                chg.append((f, sig(pa[f]), sig(pb[f])))
        for f in pb:
            if f not in pa:
                add.append(f)
        for s_, fl in a[1].items():
            if s_ in b[1]:
                if fl != b[1][s_]:
                    sfields.append(s_)
            else:
                sopaque.append(s_)
    # removed in one header but added in another within the same commit == move, not removal
    moved = set(rem) & set(add)
    rem = [f for f in rem if f not in moved]
    add = [f for f in add if f not in moved]
    surf_rem = [f for f in rem if f in surface]
    surf_chg = [x for x in chg if x[0] in surface]
    ui_num = git("show", "--format=", "--numstat", c, "--", *UI)
    ui_add = ui_del = ui_files = 0
    for l in ui_num.splitlines():
        p = l.split("\t")
        if len(p) >= 3 and p[0].isdigit():
            ui_add += int(p[0]); ui_del += int(p[1]); ui_files += 1
    info = git("log", "-1", "--format=%ad%x09%s", "--date=short", c).strip().split("\t")
    results.append({
        "commit": c[:10], "date": info[0], "subject": info[1] if len(info) > 1 else "",
        "branches": branches_of(c),
        "removed": rem, "changed": [x[0] for x in chg], "added": add, "moved": sorted(moved),
        "surface_removed": surf_rem, "surface_changed": [x[0] for x in surf_chg],
        "surface_changed_detail": surf_chg,
        "surface_callsites": sum(uirefs.get(f, 0) for f in surf_rem) + sum(uirefs.get(x[0], 0) for x in surf_chg),
        "structs_fields_changed_ui": [s for s in sfields if s in struct_ui],
        "structs_made_opaque_ui": [s for s in sopaque if s in struct_ui],
        "ui_files": ui_files, "ui_add": ui_add, "ui_del": ui_del,
    })
    sys.stderr.write(".")
json.dump(results, open(sys.argv[1], "w"), indent=1)
print(len(results))
