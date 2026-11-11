#!/usr/bin/env bash
# Regenerate the bounded masked-parent effect fixture with an isolated engine.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=engine-common.sh
source "$ROOT/scripts/engine-common.sh"

REF="${1:-GIMP_3_0_8}"
require_engine_ref "$REF"
INSTALL="$ENGINE_DIR/install/$REF"
CONSOLE="$INSTALL/bin/gimp-console"
FIXTURES="$ROOT/Engine/tests/fixtures"
[[ -x "$CONSOLE" ]] || die "no engine for $REF; run scripts/build-engine.sh $REF first."
sanitize_environment
acquire_lock

WORK="$ENGINE_DIR/fixture-work/projective-$REF"
rm -rf "$WORK"
mkdir -p "$WORK/home" "$FIXTURES"

status=0
run_with_timeout 600 "$WORK/gimp-console.log" \
  env HOME="$WORK/home" XDG_CACHE_HOME="$WORK/home/.cache" GIMP3_DIRECTORY="$WORK/home/gimp" \
      PATH="$INSTALL/bin:$PREFIX/bin:$CLEAN_PATH" \
      GI_TYPELIB_PATH="$INSTALL/lib/girepository-1.0:$PREFIX/lib/girepository-1.0" \
      GLIMS_FIXTURE_DIR="$FIXTURES" \
      GLIMS_FIXTURE_SCRIPT="$ROOT/Engine/tests/make-projective-fixture.py" \
      "$CONSOLE" -i --quit --batch-interpreter=python-fu-eval \
      -b 'import os; exec(open(os.environ["GLIMS_FIXTURE_SCRIPT"], encoding="utf-8").read())' || status=$?
(( status == 0 )) || { cat "$WORK/gimp-console.log"; die "gimp-console failed (status $status)"; }
! grep -qE "Traceback|Error" "$WORK/gimp-console.log" || { cat "$WORK/gimp-console.log"; die "the fixture script reported errors"; }
[[ -s "$FIXTURES/projective-parent-effect.xcf" ]] || die "projective-parent-effect.xcf was not written"
fixture_version="$(HOME="$WORK/home" XDG_CACHE_HOME="$WORK/home/.cache" GIMP3_DIRECTORY="$WORK/home/gimp" "$CONSOLE" --version)"
echo "-- projective-parent-effect.xcf written with $fixture_version into $FIXTURES"
