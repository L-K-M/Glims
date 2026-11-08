#!/usr/bin/env bash
# Regenerates Engine/tests/fixtures/qmask-name.xcf with GIMP's own engine:
# gimp-console of one built engine set runs Engine/tests/make-qmask-fixture.py
# through libgimp, with a throwaway home.
#
#   scripts/make-qmask-fixture.sh [GIMP_REF]   # default: GIMP_3_0_8
#
# The fixture holds a channel named "Qmask" written while the Quick Mask
# was on, like a file saved mid-edit or by an older GIMP. Build it with the
# oldest engine set so every supported version can open it, and record the
# GIMP version in Engine/tests/fixtures/README.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=engine-common.sh
source "$ROOT/scripts/engine-common.sh"

REF="${1:-GIMP_3_0_8}"
INSTALL="$ENGINE_DIR/install/$REF"
CONSOLE="$INSTALL/bin/gimp-console"
FIXTURES="$ROOT/Engine/tests/fixtures"
[[ -x "$CONSOLE" ]] || die "no engine for $REF; run scripts/build-engine.sh $REF first."
sanitize_environment
acquire_lock

WORK="$ENGINE_DIR/fixture-work/qmask-$REF"
rm -rf "$WORK"
mkdir -p "$WORK/home" "$FIXTURES"

status=0
run_with_timeout 600 "$WORK/gimp-console.log" \
  env HOME="$WORK/home" XDG_CACHE_HOME="$WORK/home/.cache" GIMP3_DIRECTORY="$WORK/home/gimp" \
      PATH="$INSTALL/bin:$PREFIX/bin:$CLEAN_PATH" \
      GI_TYPELIB_PATH="$INSTALL/lib/girepository-1.0:$PREFIX/lib/girepository-1.0" \
      GLIMS_FIXTURE_DIR="$FIXTURES" \
      "$CONSOLE" -i --quit --batch-interpreter=python-fu-eval \
      -b "exec(open('$ROOT/Engine/tests/make-qmask-fixture.py').read())" || status=$?
(( status == 0 )) || { cat "$WORK/gimp-console.log"; die "gimp-console failed (status $status)"; }
! grep -qE "Traceback|Error" "$WORK/gimp-console.log" || { cat "$WORK/gimp-console.log"; die "the fixture script reported errors"; }
[[ -s "$FIXTURES/qmask-name.xcf" ]] || die "qmask-name.xcf was not written"
echo "-- qmask-name.xcf written with $("$CONSOLE" --version) into $FIXTURES"
