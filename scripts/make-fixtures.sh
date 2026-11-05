#!/usr/bin/env bash
# Regenerates the engine conformance fixtures in Engine/tests/fixtures with
# GIMP's own engine: gimp-console of one built engine set runs
# Engine/tests/make-fixtures.py through libgimp, with a throwaway home.
#
#   scripts/make-fixtures.sh [GIMP_REF]   # default: GIMP_3_2_0, the adapter's starting tag
#
# Commit the fixtures with the GIMP version that made them (fixtures/README.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=engine-common.sh
source "$ROOT/scripts/engine-common.sh"

REF="${1:-GIMP_3_2_0}"
INSTALL="$ENGINE_DIR/install/$REF"
CONSOLE="$INSTALL/bin/gimp-console"
FIXTURES="$ROOT/Engine/tests/fixtures"
[[ -x "$CONSOLE" ]] || die "no engine for $REF; run scripts/build-engine.sh $REF first."
sanitize_environment
acquire_lock

WORK="$ENGINE_DIR/fixture-work/$REF"
rm -rf "$WORK"
mkdir -p "$WORK/home" "$FIXTURES"

status=0
run_with_timeout 600 "$WORK/gimp-console.log" \
  env HOME="$WORK/home" XDG_CACHE_HOME="$WORK/home/.cache" GIMP3_DIRECTORY="$WORK/home/gimp" \
      PATH="$INSTALL/bin:$PREFIX/bin:$CLEAN_PATH" \
      GI_TYPELIB_PATH="$INSTALL/lib/girepository-1.0:$PREFIX/lib/girepository-1.0" \
      GLIMS_FIXTURE_DIR="$FIXTURES" \
      "$CONSOLE" -i --quit --batch-interpreter=python-fu-eval \
      -b "exec(open('$ROOT/Engine/tests/make-fixtures.py').read())" || status=$?
(( status == 0 )) || { cat "$WORK/gimp-console.log"; die "gimp-console failed (status $status)"; }
! grep -qE "Traceback|Error" "$WORK/gimp-console.log" || { cat "$WORK/gimp-console.log"; die "the fixture script reported errors"; }
for file in composite.xcf composite.png; do
  [[ -s "$FIXTURES/$file" ]] || die "$file was not written"
done
echo "-- fixtures written with $("$CONSOLE" --version) into $FIXTURES"
