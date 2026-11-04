#!/bin/bash
cd /tmp/gimp-fork-research/full-apichurn.git
E="app/core app/paint app/gegl app/pdb app/plug-in app/file app/file-data app/xcf app/text app/path app/vectors app/operations app/config libgimpbase libgimpcolor libgimpconfig libgimpmath"
U="app/tools app/display app/actions app/dialogs app/widgets app/gui app/menus app/propgui"
F=$(cat /tmp/gimp-fork-research/apichurn-out/focus_files.txt | tr '\n' ' ')
for r in GIMP_3_0_0..GIMP_3_0_2 GIMP_3_0_2..GIMP_3_0_4 GIMP_3_0_4..GIMP_3_0_6 GIMP_3_0_6..GIMP_3_0_8 GIMP_3_0_8..GIMP_3_2_0 GIMP_3_2_0..GIMP_3_2_2 GIMP_3_2_2..GIMP_3_2_4 GIMP_3_2_4..GIMP_3_2_6 GIMP_3_2_6..GIMP_3_2_8 GIMP_3_2_8..master; do
  git rev-list $r -- $E | sort > /tmp/e.$$; git rev-list $r -- $U | sort > /tmp/u.$$; git rev-list $r -- $F 2>/dev/null | sort > /tmp/f.$$
  both=$(comm -12 /tmp/e.$$ /tmp/u.$$ | wc -l); eo=$(comm -23 /tmp/e.$$ /tmp/u.$$ | wc -l); uo=$(comm -13 /tmp/e.$$ /tmp/u.$$ | wc -l); fo=$(comm -13 /tmp/e.$$ /tmp/f.$$ | wc -l)
  echo "$r total=$(git rev-list --count $r) engine_only=$eo ui_only=$uo both=$both focusUI_without_engine=$fo"
done
rm -f /tmp/e.$$ /tmp/u.$$ /tmp/f.$$
