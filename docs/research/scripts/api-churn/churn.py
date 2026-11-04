#!/usr/bin/env python3
"""Compare API snapshots between tags.  usage: python3 -I churn.py OUTDIR WORKDIR T1:T2 [T1:T2 ...]"""
import json, os, re, sys, difflib, fnmatch
from collections import Counter, defaultdict

OUT, WORK = sys.argv[1], sys.argv[2]
PAIRS = [p.split(":") for p in sys.argv[3:]]

FOCUS_PATTERNS = [
    # tools for a classic editor
    "app/tools/gimptool.c", "app/tools/gimptool.h", "app/tools/gimpdrawtool.c", "app/tools/gimptoolcontrol.c",
    "app/tools/tool_manager.c", "app/tools/gimp-tools.c", "app/tools/gimptools-utils.c",
    "app/tools/gimpmovetool.c", "app/tools/gimpmoveoptions.c", "app/tools/gimpeditselectiontool.c",
    "app/tools/gimpselectiontool.c", "app/tools/gimpselectionoptions.c",
    "app/tools/gimprectangleselecttool.c", "app/tools/gimprectangleselectoptions.c",
    "app/tools/gimprectangleoptions.c", "app/tools/gimpellipseselecttool.c",
    "app/tools/gimpfreeselecttool.c", "app/tools/gimppolygonselecttool.c",
    "app/tools/gimpregionselecttool.c", "app/tools/gimpregionselectoptions.c", "app/tools/gimpfuzzyselecttool.c",
    "app/tools/gimpcroptool.c", "app/tools/gimpcropoptions.c",
    "app/tools/gimppainttool.c", "app/tools/gimppainttool-paint.c", "app/tools/gimpbrushtool.c",
    "app/tools/gimppaintoptions-gui.c", "app/tools/gimppaintbrushtool.c", "app/tools/gimppenciltool.c",
    "app/tools/gimpairbrushtool.c", "app/tools/gimperasertool.c",
    "app/tools/gimpsourcetool.c", "app/tools/gimpclonetool.c", "app/tools/gimpcloneoptions-gui.c",
    "app/tools/gimphealtool.c", "app/tools/gimpsmudgetool.c", "app/tools/gimpconvolvetool.c",
    "app/tools/gimpdodgeburntool.c",
    "app/tools/gimppathtool.c", "app/tools/gimppathoptions.c", "app/tools/gimpvectortool.c", "app/tools/gimpvectoroptions.c",
    "app/tools/gimptexttool.c", "app/tools/gimptexttool-editor.c", "app/tools/gimptextoptions.c",
    "app/tools/gimpgradienttool.c", "app/tools/gimpgradientoptions.c",
    "app/tools/gimpbucketfilltool.c", "app/tools/gimpbucketfilloptions.c",
    "app/tools/gimpcolortool.c", "app/tools/gimpcolorpickertool.c", "app/tools/gimpcolorpickeroptions.c",
    "app/tools/gimpcoloroptions.c", "app/tools/gimpmagnifytool.c", "app/tools/gimpmagnifyoptions.c",
    # filters through GimpDrawableFilter
    "app/tools/gimpfiltertool.c", "app/tools/gimpfiltertool-settings.c", "app/tools/gimpoperationtool.c",
    "app/tools/gimpfilteroptions.c", "app/actions/filters-commands.c",
    # canvas / display
    "app/display/gimpdisplay.c", "app/display/gimpdisplay-handlers.c", "app/display/gimpdisplayshell.c",
    "app/display/gimpdisplayshell-render.c", "app/display/gimpdisplayshell-draw.c",
    "app/display/gimpdisplayshell-scale.c", "app/display/gimpdisplayshell-scroll.c",
    "app/display/gimpdisplayshell-tool-events.c", "app/display/gimpdisplayshell-handlers.c",
    "app/display/gimpdisplayshell-transform.c", "app/display/gimpdisplayshell-selection.c",
    "app/display/gimpdisplayshell-title.c", "app/display/gimpstatusbar.c",
    # palettes
    "app/widgets/gimplayertreeview.c", "app/widgets/gimpitemtreeview.c", "app/widgets/gimpdrawabletreeview.c",
    "app/widgets/gimpchanneltreeview.c", "app/widgets/gimppathtreeview.c", "app/widgets/gimpvectorstreeview.c",
    "app/widgets/gimpundoeditor.c", "app/widgets/gimpnavigationview.c", "app/display/gimpnavigationeditor.c",
    "app/display/gimpcursorview.c", "app/widgets/gimpcoloreditor.c", "app/widgets/gimpfgbgeditor.c",
    "app/widgets/gimpfgbgview.c", "app/widgets/gimpbrushfactoryview.c", "app/widgets/gimpdatafactoryview.c",
    "app/widgets/gimpviewrenderer.c", "app/widgets/gimpviewrendererlayer.c", "app/widgets/gimpviewrendererdrawable.c",
    "app/widgets/gimpviewrendererbrush.c", "app/widgets/gimpviewrendererimage.c",
    # commands
    "app/actions/layers-commands.c", "app/actions/channels-commands.c", "app/actions/paths-commands.c",
    "app/actions/vectors-commands.c", "app/actions/edit-commands.c", "app/actions/select-commands.c",
    "app/actions/image-commands.c", "app/actions/file-commands.c", "app/actions/view-commands.c",
    "app/actions/drawable-commands.c", "app/actions/items-commands.c",
    "app/dialogs/file-open-dialog.c", "app/dialogs/file-save-dialog.c", "app/dialogs/layer-options-dialog.c",
    "app/dialogs/image-new-dialog.c",
]
FOCUS_PATTERNS = set(FOCUS_PATTERNS)


def load(t):
    with open(os.path.join(OUT, t + ".json")) as f:
        return json.load(f)


def sig(v):
    return v["ret"] + " (" + ", ".join(v["params"]) + ")"


def ui_refs(snap, name, focus=False):
    d = snap["ui_ids"].get(name, {})
    if focus:
        return sum(c for f, c in d.items() if f in FOCUS_PATTERNS)
    return sum(d.values())


def surface(snap, focus=False):
    return {f for f in snap["funcs"] if ui_refs(snap, f, focus) > 0}


def type_map(a, b):
    """types present in a but not b paired with types in b not in a by name similarity"""
    ra = set(a["types"]) - set(b["types"])
    rb = set(b["types"]) - set(a["types"])
    m = {}
    for x in ra:
        best = max(rb, key=lambda y: difflib.SequenceMatcher(None, x, y).ratio(), default=None)
        if best and difflib.SequenceMatcher(None, x, best).ratio() >= 0.6:
            m[x] = best
    return m


def apply_map(s, tm):
    for k, v in tm.items():
        s = re.sub(r"\b%s\b" % re.escape(k), v, s)
    return s


def name_norm(n, tm):
    # translate snake-case form of renamed types (e.g. gimp_vectors -> gimp_path)
    for k, v in tm.items():
        ks = re.sub(r"(?<!^)([A-Z])", r"_\1", k).lower()
        vs = re.sub(r"(?<!^)([A-Z])", r"_\1", v).lower()
        n = n.replace(ks, vs)
    return n


def compare(t1, t2):
    a, b = load(t1), load(t2)
    tm = type_map(a, b)
    # manual knowledge: GimpVectors -> GimpPath family is the big one
    res = {"interval": f"{t1}->{t2}", "type_map": tm}
    fa, fb = a["funcs"], b["funcs"]
    added_engine = set(fb) - set(fa)
    for scope in ("full", "focus"):
        S = surface(a, scope == "focus")
        removed, changed, renamed, moved = [], [], [], []
        for f in sorted(S):
            if f in fb:
                if sig(fa[f]) != sig(fb[f]):
                    mech = apply_map(sig(fa[f]), tm) == sig(fb[f])
                    changed.append({"name": f, "old": sig(fa[f]), "new": sig(fb[f]), "mechanical": mech,
                                    "refs": ui_refs(a, f), "refs_focus": ui_refs(a, f, True)})
                elif fa[f]["file"] != fb[f]["file"]:
                    moved.append({"name": f, "old": fa[f]["file"], "new": fb[f]["file"], "refs": ui_refs(a, f)})
            else:
                nn = name_norm(f, tm)
                cand = None
                if nn in added_engine:
                    cand = nn
                else:
                    best, br = None, 0
                    for g in added_engine:
                        r = difflib.SequenceMatcher(None, nn, g).ratio()
                        if r > br:
                            best, br = g, r
                    if best and (br >= 0.85 or (br >= 0.7 and apply_map(sig(fa[f]), tm) == sig(fb[best]))):
                        cand = best
                entry = {"name": f, "old": sig(fa[f]), "refs": ui_refs(a, f), "refs_focus": ui_refs(a, f, True),
                         "still_in_ui": ui_refs(b, f) > 0}
                if cand:
                    entry["new_name"] = cand
                    entry["new"] = sig(fb[cand])
                    entry["same_sig_after_typemap"] = apply_map(sig(fa[f]), tm) == sig(fb[cand])
                    renamed.append(entry)
                else:
                    removed.append(entry)
        Sb = surface(b, scope == "focus")
        res[scope] = {
            "surface_size_t1": len(S), "surface_size_t2": len(Sb),
            "removed": removed, "renamed": renamed, "changed": changed, "moved": moved,
            "new_in_surface": sorted(Sb - S),
            "new_api_in_surface": sorted((Sb - S) & added_engine),
        }
    # engine-wide (all declared, not only UI-referenced)
    res["engine_all"] = {
        "declared_t1": len(fa), "declared_t2": len(fb),
        "removed": len(set(fa) - set(fb)), "added": len(set(fb) - set(fa)),
        "changed": sum(1 for f in set(fa) & set(fb) if sig(fa[f]) != sig(fb[f])),
    }
    # types
    ui_t = lambda s, t: ui_refs(s, t) + ui_refs(s, s["types"][t]["macro"] or "")
    tr = [t for t in a["types"] if t not in b["types"] and ui_t(a, t) > 0]
    res["types_removed_or_renamed"] = [{"type": t, "to": tm.get(t), "refs": ui_t(a, t)} for t in sorted(tr)]
    res["types_added"] = sorted(set(b["types"]) - set(a["types"]))
    # structs: field changes for structs whose name is referenced from UI
    sc = []
    for s_, v in a["structs"].items():
        if ui_refs(a, s_) == 0:
            continue
        if s_ not in b["structs"]:
            sc.append({"struct": s_, "change": "removed", "to": tm.get(s_) or tm.get(s_.replace("Class", "")),
                       "refs": ui_refs(a, s_)})
            continue
        fa_ = v["fields"]; fb_ = b["structs"][s_]["fields"]
        if fa_ != fb_:
            rem = [x for x in fa_ if x not in fb_]
            add = [x for x in fb_ if x not in fa_]
            def fname(d):
                m = re.findall(r"\(\s*\*\s*(\w+)\s*\)|(\w+)\s*(?:\[[^\]]*\])*\s*$", d)
                return [x or y for x, y in m][:1]
            remn = [n for d in rem for n in fname(d)]
            ui_hit = [n for n in remn if a["ui_arrow"].get(n, 0) > 0]
            sc.append({"struct": s_, "change": "fields", "removed_fields": rem, "added_fields": add,
                       "removed_field_names_seen_in_ui_member_access": ui_hit, "refs": ui_refs(a, s_)})
    res["structs"] = sc
    # enums
    res["enums_removed"] = [{"enum": e, "refs": ui_refs(a, e)} for e in sorted(set(a["enums"]) - set(b["enums"]))
                            if ui_refs(a, e) > 0]
    res["enums_added"] = len(set(b["enums"]) - set(a["enums"]))
    # signals and properties referenced as strings from UI
    def strings(s, n):
        return sum(s["ui_strings"].get(n, {}).values())
    sig_rem = []
    for n, cls in a["signals"].items():
        if strings(a, n) == 0:
            continue
        if n not in b["signals"]:
            sig_rem.append({"signal": n, "classes": sorted(set(cls)), "ui_refs": strings(a, n)})
        else:
            lost = sorted(set(cls) - set(b["signals"][n]))
            if lost:
                sig_rem.append({"signal": n, "lost_from": lost, "now": sorted(set(b["signals"][n])), "ui_refs": strings(a, n)})
    res["signals_removed"] = sig_rem
    res["signals_added"] = sorted(set(b["signals"]) - set(a["signals"]))
    def props(s):
        d = defaultdict(set)
        for n, cls in s["props"].items():
            for c in cls:
                if not c.endswith("-cmds") and c not in ("internal-procs",):
                    d[n].add(c)
        return d
    pa, pb = props(a), props(b)
    pr = []
    for n, cls in pa.items():
        if strings(a, n) == 0:
            continue
        if n not in pb:
            pr.append({"prop": n, "classes": sorted(cls), "ui_refs": strings(a, n)})
        else:
            lost = sorted(cls - pb[n])
            if lost:
                pr.append({"prop": n, "lost_from": lost, "now": sorted(pb[n]), "ui_refs": strings(a, n)})
    res["props_removed"] = pr
    res["props_added"] = sorted(set(pb) - set(pa))
    return res


if __name__ == "__main__":
    allres = []
    for t1, t2 in PAIRS:
        r = compare(t1, t2)
        allres.append(r)
        F, Fo = r["full"], r["focus"]
        def cnt(x):
            return (len(x["removed"]), len(x["renamed"]), len(x["changed"]),
                    sum(1 for c in x["changed"] if c["mechanical"]), len(x["moved"]))
        def refs(x):
            return (sum(e["refs"] for e in x["removed"]) + sum(e["refs"] for e in x["renamed"]) +
                    sum(e["refs"] for e in x["changed"]))
        def refs_f(x):
            return (sum(e["refs_focus"] for e in x["removed"]) + sum(e["refs_focus"] for e in x["renamed"]) +
                    sum(e["refs_focus"] for e in x["changed"]))
        print(f"{t1}->{t2}: surf {F['surface_size_t1']}->{F['surface_size_t2']} rem/ren/chg(mech)/moved {cnt(F)} refs {refs(F)} | "
              f"focus {Fo['surface_size_t1']} {cnt(Fo)} refs_focus {refs_f(Fo)} | engine {r['engine_all']} | "
              f"types {len(r['types_removed_or_renamed'])} structs {len(r['structs'])} enums {len(r['enums_removed'])} "
              f"sig {len(r['signals_removed'])} props {len(r['props_removed'])} newapi {len(F['new_api_in_surface'])}")
    with open(os.path.join(OUT, "churn.json"), "w") as f:
        json.dump(allres, f, indent=1)
