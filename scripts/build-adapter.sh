#!/usr/bin/env bash
# Builds the engine adapter in Engine/ against one engine set built by
# scripts/build-engine.sh, and optionally runs its conformance tests.
#
#   scripts/build-adapter.sh [GIMP_REF]          # default: the pinned engine (first set)
#   scripts/build-adapter.sh --test [GIMP_REF]   # build, then run the conformance tests
#   scripts/build-adapter.sh --check [GIMP_REF]  # print the resolved configuration
#
# Output in _engine/adapter/<GIMP_REF>/: libglimsengine.dylib, which exports
# only glims_engine_get_api(), and the glims-engine-tests runner. The adapter
# is compiled with the flags of GIMP's gimp-console and linked with its object
# files minus main.c.o, against the installed engine (scripts/adapter-flags.py
# reads both from the engine's meson build, so nothing is hard-coded).
#
# The tests start the engine with a throwaway HOME, user directory and cache
# under the output directory; the user's settings are never touched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=engine-common.sh
source "$ROOT/scripts/engine-common.sh"

MODE=build
REF=""
for arg in "$@"; do
  case "$arg" in
    --test) MODE=test ;;
    --check) MODE=check ;;
    -h|--help) awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    -*) die "unknown option '$arg' (see --help)" ;;
    *) [[ -z "$REF" ]] || die "only one GIMP ref at a time"; REF="$arg" ;;
  esac
done
[[ -n "$REF" ]] || REF="${ENGINE_SETS%% *}"
REF="${REF%%:*}"

INSTALL="$ENGINE_DIR/install/$REF"
BUILD="$ENGINE_DIR/build/$REF/gimp"
OUT="$ENGINE_DIR/adapter/$REF"
INCLUDE="$ROOT/Sources/CGlimsEngine/include"

if [[ "$MODE" == check ]]; then
  echo "build-adapter --check"
  echo "  GIMP:     $REF ($( [[ -f "$INSTALL/.glims-engine-stamp" ]] && echo built || echo 'not built; run scripts/build-engine.sh'))"
  echo "  engine:   $INSTALL"
  echo "  output:   $OUT"
  exit 0
fi

[[ -f "$INSTALL/.glims-engine-stamp" && -f "$BUILD/build.ninja" ]] ||
  die "the engine for $REF is not built; run scripts/build-engine.sh $REF first."
sanitize_environment
acquire_lock
export PATH="$PREFIX/bin:$CLEAN_PATH"

rm -rf "$OUT/obj"
mkdir -p "$OUT/obj"

echo "==> Reading GIMP's build flags"
meson introspect --targets "$BUILD" > "$OUT/targets.json"
python3 -I "$ROOT/scripts/adapter-flags.py" "$OUT/targets.json" "$BUILD" "$INSTALL" "$OUT"

TYPELIB_PATH="$INSTALL/lib/girepository-1.0:$PREFIX/lib/girepository-1.0"

echo "==> Compiling the adapter"
for source in "$ROOT"/Engine/*.c; do
  object="$OUT/obj/$(basename "${source%.c}").o"
  xcrun clang @"$OUT/compile.rsp" -I"$INCLUDE" -I"$ROOT/Engine" \
    -DGLIMS_ENGINE_TYPELIB_PATH="\"$TYPELIB_PATH\"" -DGLIMS_ENGINE_BIN_PATH="\"$INSTALL/bin\"" \
    -fvisibility=hidden -Wall -Werror=implicit-function-declaration \
    -c "$source" -o "$object" || die "compiling $(basename "$source") failed"
done

echo "==> Linking libglimsengine.dylib"
xcrun clang++ -dynamiclib -o "$OUT/libglimsengine.dylib" \
  "$OUT"/obj/*.o @"$OUT/objects.rsp" @"$OUT/link.rsp" \
  -install_name @rpath/libglimsengine.dylib \
  -Wl,-exported_symbol,_glims_engine_get_api || die "linking the adapter failed"

echo "==> Building the conformance tests"
xcrun clang -std=c11 -Wall -Wextra -Werror -I"$INCLUDE" \
  "$ROOT/Engine/tests/engine-tests.c" -o "$OUT/glims-engine-tests" || die "building the tests failed"

exported="$(nm -gU "$OUT/libglimsengine.dylib" | awk '{print $3}')"
[[ "$exported" == "_glims_engine_get_api" ]] || die "the adapter exports more than glims_engine_get_api: $exported"
echo "-- $OUT/libglimsengine.dylib ($(du -h "$OUT/libglimsengine.dylib" | cut -f1)), exports only glims_engine_get_api"

if [[ "$MODE" == test ]]; then
  echo "==> Running the conformance tests"
  WORK="$OUT/test-work"
  rm -rf "$WORK"
  mkdir -p "$WORK/home"
  status=0
  run_with_timeout 900 "$OUT/test.log" \
    env HOME="$WORK/home" XDG_CACHE_HOME="$WORK/cache" \
        "$OUT/glims-engine-tests" "$OUT/libglimsengine.dylib" "$WORK" "$ROOT/Engine/tests/fixtures" || status=$?
  cat "$OUT/test.log"
  (( status != 124 )) || die "the conformance tests did not finish within 15 minutes"
  (( status == 0 )) || die "the conformance tests failed (status $status)"
  ! grep -qE "Traceback|Failed to load shared library|^env: .*: No such file" "$OUT/test.log" ||
    die "plug-ins reported load errors during the tests; see $OUT/test.log"
  criticals="$(grep -c "CRITICAL" "$OUT/test.log" || true)"
  (( criticals == 0 )) || echo "!! $criticals GLib CRITICAL message(s) during the tests; see $OUT/test.log"
fi
