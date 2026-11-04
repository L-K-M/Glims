#!/usr/bin/env python3
"""Attribute prototype changes to commits. usage: python3 -I attrib.py items.tsv"""
import subprocess, sys, re
sys.path.insert(0, "/tmp/gimp-fork-research/apichurn-scripts")
from snapshot import parse_header_protos

GIT = ["git", "-C", "/tmp/gimp-fork-research/full-apichurn.git"]
UI = ["app/tools", "app/display", "app/actions", "app/dialogs", "app/widgets", "app/gui", "app/menus", "app/propgui"]


def git(*a):
    r = subprocess.run(GIT + list(a), capture_output=True, text=True, errors="replace")
    return r.stdout


def proto_at(rev, path, name):
    src = git("show", f"{rev}:{path}")
    if not src:
        return None
    p = parse_header_protos(src)[0]
    v = p.get(name)
    return None if v is None else v["ret"] + " (" + ", ".join(v["params"]) + ")"


seen = set()
for line in open(sys.argv[1]):
    a, b, kind, name, newname, hdr, refs, rf = line.rstrip("\n").split("\t")
    paths = [hdr] + ([hdr.replace("app/vectors/", "app/path/")] if "app/vectors/" in hdr else [])
    commits = git("log", "--format=%H", "--reverse", f"{a}..{b}", "--", *paths).split()
    for c in commits:
        hits = []
        for p in paths:
            before = proto_at(c + "^", p, name)
            after = proto_at(c, p, name)
            if before is not None and before != after:
                hits.append((p, before, after))
        if not hits:
            continue
        key = (c, name)
        if key in seen:
            continue
        seen.add(key)
        d = git("show", "--format=", "--unified=0", c, "--", *UI)
        target = newname or name
        minus = sum(1 for l in d.splitlines() if l.startswith("-") and not l.startswith("---") and name in l)
        plus = sum(1 for l in d.splitlines() if l.startswith("+") and not l.startswith("+++") and target in l)
        uifiles = len(git("show", "--format=", "--name-only", c, "--", *UI).split())
        allfiles = len(git("show", "--format=", "--name-only", c).split())
        subj = git("log", "-1", "--format=%ad %s", "--date=short", c).strip()
        after = hits[0][2]
        print("\t".join([f"{a}..{b}", kind, name, c[:8], f"refs_t1={refs}", f"ui_minus={minus}", f"ui_plus={plus}",
                         f"ui_files={uifiles}", f"all_files={allfiles}", subj, "AFTER=" + str(after)]))
        sys.stdout.flush()
