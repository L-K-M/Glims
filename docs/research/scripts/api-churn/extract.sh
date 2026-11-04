#!/bin/bash
cd /tmp/gimp-fork-research/full-apichurn.git
P="app/core app/paint app/gegl app/pdb app/plug-in app/file app/file-data app/xcf app/text app/path app/vectors app/operations app/config app/tools app/display app/actions app/dialogs app/widgets app/gui app/menus app/propgui app/meson.build libgimpbase libgimpcolor libgimpconfig libgimpmath libgimp"
for t in GIMP_3_0_0 GIMP_3_0_2 GIMP_3_0_4 GIMP_3_0_6 GIMP_3_0_8 GIMP_3_1_2 GIMP_3_1_4 GIMP_3_2_0 GIMP_3_2_2 GIMP_3_2_4 GIMP_3_2_6 GIMP_3_2_8 master; do
  d=/tmp/gimp-fork-research/apichurn-work/$t; rm -rf $d; mkdir -p $d
  ex=""; for x in $P; do git cat-file -e $t:$x 2>/dev/null && ex="$ex $x"; done
  git archive $t -- $ex | tar -x -C $d
  echo "$t $(find $d -type f | wc -l)"
done
