#!/bin/bash
# usage: attrib.sh items.tsv
cd /tmp/gimp-fork-research/full-apichurn.git
UI="app/tools app/display app/actions app/dialogs app/widgets app/gui app/menus app/propgui"
while IFS=$'\t' read -r a b kind name newname hdr refs rf; do
  paths="$hdr"
  alt=$(echo "$hdr" | sed 's#app/vectors/#app/path/#'); [ "$alt" != "$hdr" ] && paths="$paths $alt"
  commits=$(git log --format='%h' $a..$b -G"$name" -- $paths 2>/dev/null)
  for c in $commits; do
    subj=$(git log -1 --format='%ad %s' --date=short $c)
    d=$(git show --format= --unified=0 $c -- $UI 2>/dev/null)
    minus=$(printf '%s\n' "$d" | grep -E '^-[^-]' | grep -c "$name")
    plus=$(printf '%s\n' "$d" | grep -E '^\+[^+]' | grep -c "${newname:-$name}")
    files=$(git show --format= --name-only $c -- $UI | wc -l | tr -d ' ')
    allfiles=$(git show --format= --name-only $c | wc -l | tr -d ' ')
    printf '%s\t%s\t%s\t%s\t%s\tui_minus=%s\tui_plus=%s\tui_files=%s\tall_files=%s\t%s\n' "$a..$b" "$kind" "$name" "$c" "$refs" "$minus" "$plus" "$files" "$allfiles" "$subj"
  done
done < "$1"
