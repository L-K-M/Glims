#!/usr/bin/env python3
"""Classify commits in a range by the directories they touch.
Usage: git log --no-merges --format='@@%h' --name-only A..B | python3 -I split.py [focus_files.txt]
"""
import sys, collections

ENGINE = ("app/core/", "app/paint/", "app/gegl/", "app/pdb/", "app/plug-in/", "app/file/",
          "app/file-data/", "app/xcf/", "app/text/", "app/vectors/", "app/path/",
          "app/operations/", "app/config/", "libgimpbase/", "libgimpcolor/", "libgimpconfig/",
          "libgimpmath/", "libgimpmodule/", "libgimpthumb/")
UI = ("app/actions/", "app/dialogs/", "app/display/", "app/gui/", "app/menus/", "app/tools/",
      "app/widgets/", "app/propgui/", "menus/")
focus = set()
if len(sys.argv) > 1:
    focus = {l.strip() for l in open(sys.argv[1]) if l.strip()}

commits = []
cur = None
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("@@"):
        cur = [line[2:], []]
        commits.append(cur)
    elif line and cur is not None:
        cur[1].append(line)

c = collections.Counter()
ui_only_focus = []
for h, files in commits:
    # ignore tests, po, docs for classification
    eng = any(f.startswith(ENGINE) and "/tests/" not in f for f in files)
    ui = any(f.startswith(UI) for f in files)
    foc = any(f in focus for f in files)
    if eng and ui:
        c["both"] += 1
        if foc:
            c["both_focus"] += 1
    elif eng:
        c["engine_only"] += 1
    elif ui:
        c["ui_only"] += 1
        if foc:
            c["ui_only_focus"] += 1; ui_only_focus.append(h)
    else:
        c["neither"] += 1
c["total"] = len(commits)
print(dict(c))
if "--list" in sys.argv:
    print(" ".join(ui_only_focus))
