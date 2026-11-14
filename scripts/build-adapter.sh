#!/usr/bin/env bash
# Builds the engine adapter in Engine/ against one engine set built by
# scripts/build-engine.sh, and optionally runs its conformance tests.
#
#   scripts/build-adapter.sh [GIMP_REF]          # default: the pinned engine (first set)
#   scripts/build-adapter.sh --test [GIMP_REF]   # build, then run the conformance tests
#   scripts/build-adapter.sh --perf [GIMP_REF]   # build, then run the performance pass
#   scripts/build-adapter.sh --check [GIMP_REF]  # print the resolved configuration
#
# Output in _engine/adapter/<GIMP_REF>/ (or GLIMS_ADAPTER_ROOT/<GIMP_REF>/):
# libglimsengine.dylib, which exports
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
    --perf) MODE=perf ;;
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
ADAPTER_ROOT="${GLIMS_ADAPTER_ROOT:-$ENGINE_DIR/adapter}"
[[ "$ADAPTER_ROOT" == /* ]] || die "GLIMS_ADAPTER_ROOT must be an absolute directory."
OUT="$ADAPTER_ROOT/$REF"
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
# Worktrees share these trees through symlinks. Embed and link their physical
# locations so removing the worktree does not break plug-in discovery or the
# response files used by native fixtures.
INSTALL="$(cd "$INSTALL" && pwd -P)"
BUILD="$(cd "$BUILD" && pwd -P)"
PREFIX="$(cd "$PREFIX" && pwd -P)"
sanitize_environment
acquire_lock
export PATH="$PREFIX/bin:$CLEAN_PATH"

rm -rf "$OUT/obj"
mkdir -p "$OUT/obj"

echo "==> Reading GIMP's build flags"
meson introspect --targets "$BUILD" > "$OUT/targets.json"
python3 -I "$ROOT/scripts/adapter-flags.py" "$OUT/targets.json" "$BUILD" "$INSTALL" "$OUT"

# Compression recovery and TIFF import preparation run in the adapter.
# Keep its existing prefix dependencies in the frozen response file so
# isolated native fixtures and bundle collection use the same link inputs.
python3 -I - "$OUT/link.rsp" "$PREFIX/lib/libbz2.dylib" "$PREFIX/lib/liblzma.dylib" "$PREFIX/lib/libtiff.dylib" <<'PYCOMPRESSION'
from pathlib import Path
import shlex
import sys
libraries = [Path(value) for value in sys.argv[2:]]
if not all(path.is_file() for path in libraries):
    raise SystemExit("The dependency prefix needs its bzip2, liblzma and libtiff libraries")
with Path(sys.argv[1]).open("a") as output:
    output.write("\n" + shlex.join(map(str, libraries)) + "\n")
PYCOMPRESSION

TYPELIB_PATH="$INSTALL/lib/girepository-1.0:$PREFIX/lib/girepository-1.0"

echo "==> Compiling the adapter"
for source in "$ROOT"/Engine/*.c; do
  object="$OUT/obj/$(basename "${source%.c}").o"
  xcrun clang @"$OUT/compile.rsp" -I"$INCLUDE" -I"$ROOT/Engine" \
    -DGLIMS_ENGINE_TYPELIB_PATH="\"$TYPELIB_PATH\"" -DGLIMS_ENGINE_BIN_PATH="\"$INSTALL/bin\"" \
    -fvisibility=hidden -Wall -Werror=implicit-function-declaration \
    -c "$source" -o "$object" || die "compiling $(basename "$source") failed"
done

for source in "$ROOT"/Engine/*.cpp; do
  [[ -f "$source" ]] || continue
  object="$OUT/obj/$(basename "${source%.cpp}").o"
  xcrun clang++ @"$OUT/compile-cxx.rsp" -I"$INCLUDE" -I"$ROOT/Engine" \
    -fvisibility=hidden -fvisibility-inlines-hidden -Wall \
    -c "$source" -o "$object" || die "compiling $(basename "$source") failed"
done

echo "==> Linking libglimsengine.dylib"
xcrun clang++ -dynamiclib -o "$OUT/libglimsengine.dylib" \
  "$OUT"/obj/*.o @"$OUT/objects.rsp" @"$OUT/link.rsp" \
  -install_name @rpath/libglimsengine.dylib \
  -Wl,-exported_symbol,_glims_engine_get_api || die "linking the adapter failed"

echo "==> Building the conformance tests and the performance pass"
for program in engine-tests engine-perf bitmap-psd-engine-tests duotone-preservation-tests duotone-export-tests psd-composite-tests; do
  xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -I"$INCLUDE" \
    "$ROOT/Engine/tests/$program.c" -o "$OUT/glims-$program" || die "building $program failed"
done

# Exercise the actual compiled streaming decoders without starting GIMP.
xcrun clang @"$OUT/compile.rsp" -I"$ROOT/Engine" -std=c11 -O2 -Wall -Wextra \
  -c "$ROOT/Engine/tests/xcf-compressed-tests.c" -o "$OUT/xcf-compressed-tests.o"
xcrun clang++ -o "$OUT/glims-xcf-compressed-tests" "$OUT/xcf-compressed-tests.o" \
  "$OUT/obj/xcf-compressed.o" "$OUT/obj/xcf-gzip.o" @"$OUT/link.rsp"

# Exercise TIFF chain filtering and malformed-file admission without GIMP.
xcrun clang @"$OUT/compile.rsp" -I"$ROOT/Engine" -std=c11 -O2 -Wall -Wextra \
  -c "$ROOT/Engine/tests/tiff-import-tests.c" -o "$OUT/tiff-import-tests.o"
xcrun clang++ -o "$OUT/glims-tiff-import-tests" "$OUT/tiff-import-tests.o" \
  "$OUT/obj/tiff-import.o" @"$OUT/link.rsp"

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
  # Verify the real public Bitmap export, including GIMP's own PSD import.
  BITMAP_WORK="$WORK/bitmap"
  mkdir -p "$BITMAP_WORK/home" "$BITMAP_WORK/cache"
  status=0
  run_with_timeout 180 "$OUT/bitmap-psd-test.log" \
    env HOME="$BITMAP_WORK/home" XDG_CACHE_HOME="$BITMAP_WORK/cache" \
        "$OUT/glims-bitmap-psd-engine-tests" "$OUT/libglimsengine.dylib" "$BITMAP_WORK" || status=$?
  cat "$OUT/bitmap-psd-test.log"
  (( status == 0 )) || die "the Bitmap PSD engine tests failed (status $status)"
  DUOTONE_WORK="$WORK/duotone"
  mkdir -p "$DUOTONE_WORK/home" "$DUOTONE_WORK/cache"
  status=0
  run_with_timeout 180 "$OUT/duotone-preservation-test.log" \
    env HOME="$DUOTONE_WORK/home" XDG_CACHE_HOME="$DUOTONE_WORK/cache" \
        "$OUT/glims-duotone-preservation-tests" "$OUT/libglimsengine.dylib" "$DUOTONE_WORK" "$ROOT/Engine/tests/fixtures" || status=$?
  cat "$OUT/duotone-preservation-test.log"
  (( status == 0 )) || die "the Duotone preservation tests failed (status $status)"
  EXPORT_WORK="$WORK/duotone-export"
  mkdir -p "$EXPORT_WORK/home" "$EXPORT_WORK/cache"
  status=0
  run_with_timeout 180 "$OUT/duotone-export-test.log" \
    env HOME="$EXPORT_WORK/home" XDG_CACHE_HOME="$EXPORT_WORK/cache" \
        "$OUT/glims-duotone-export-tests" "$OUT/libglimsengine.dylib" "$EXPORT_WORK" "$ROOT/Engine/tests/fixtures" || status=$?
  cat "$OUT/duotone-export-test.log"
  (( status == 0 )) || die "the Duotone export tests failed (status $status)"
  COMPOSITE_WORK="$WORK/psd-composite"
  mkdir -p "$COMPOSITE_WORK/home" "$COMPOSITE_WORK/cache"
  status=0
  run_with_timeout 180 "$OUT/psd-composite-test.log" \
    env HOME="$COMPOSITE_WORK/home" XDG_CACHE_HOME="$COMPOSITE_WORK/cache" \
        "$OUT/glims-psd-composite-tests" "$OUT/libglimsengine.dylib" "$COMPOSITE_WORK" "$ROOT/Engine/tests/fixtures" || status=$?
  cat "$OUT/psd-composite-test.log"
  (( status == 0 )) || die "the Photoshop composite tests failed (status $status)"
  status=0
  run_with_timeout 60 "$OUT/codec-test.log" \
    env HOME="$WORK/home" XDG_CACHE_HOME="$WORK/cache" \
        "$OUT/glims-xcf-compressed-tests" || status=$?
  cat "$OUT/codec-test.log"
  (( status == 0 )) || die "the compressed XCF codec tests failed (status $status)"
  status=0
  run_with_timeout 60 "$OUT/tiff-import-test.log" \
    env HOME="$WORK/home" XDG_CACHE_HOME="$WORK/cache" \
        "$OUT/glims-tiff-import-tests" "$WORK" || status=$?
  cat "$OUT/tiff-import-test.log"
  (( status == 0 )) || die "the TIFF import preparation tests failed (status $status)"
  status=0
  run_with_timeout 600 "$OUT/duotone-alternate-metadata-test.log" \
    python3 "$ROOT/scripts/test-duotone-alternate-metadata.py" \
      --ref "$REF" --adapter-root "$ADAPTER_ROOT" --timeout 180 || status=$?
  cat "$OUT/duotone-alternate-metadata-test.log"
  (( status == 0 )) || die "the Duotone alternate metadata tests failed (status $status)"
  status=0
  run_with_timeout 600 "$OUT/duotone-alternate-export-test.log" \
    python3 "$ROOT/scripts/test-duotone-alternate-export.py" \
      --ref "$REF" --adapter-root "$ADAPTER_ROOT" --timeout 180 || status=$?
  cat "$OUT/duotone-alternate-export-test.log"
  (( status == 0 )) || die "the Duotone alternate export tests failed (status $status)"
fi

if [[ "$MODE" == perf ]]; then
  # The 24 MP test image is made once by GIMP 3.2.0's gimp-console, which
  # every later engine also opens.
  PERF_IMAGE="$ENGINE_DIR/perf/perf-24mp-20-layers.xcf"
  MAKER="$ENGINE_DIR/install/GIMP_3_2_0"
  if [[ ! -s "$PERF_IMAGE" ]]; then
    [[ -x "$MAKER/bin/gimp-console" ]] || die "the performance image is made with GIMP_3_2_0; build that engine first."
    echo "==> Making the 24 MP performance image (once)"
    mkdir -p "$ENGINE_DIR/perf/home"
    status=0
    run_with_timeout 1800 "$ENGINE_DIR/perf/make.log" \
      env HOME="$ENGINE_DIR/perf/home" XDG_CACHE_HOME="$ENGINE_DIR/perf/home/.cache" \
          GIMP3_DIRECTORY="$ENGINE_DIR/perf/home/gimp" PATH="$MAKER/bin:$PREFIX/bin:$CLEAN_PATH" \
          GI_TYPELIB_PATH="$MAKER/lib/girepository-1.0:$PREFIX/lib/girepository-1.0" \
          GLIMS_PERF_IMAGE="$PERF_IMAGE" \
          "$MAKER/bin/gimp-console" -i --quit --batch-interpreter=python-fu-eval \
          -b "exec(open('$ROOT/Engine/tests/make-perf-image.py').read())" || status=$?
    (( status == 0 )) && [[ -s "$PERF_IMAGE" ]] || { cat "$ENGINE_DIR/perf/make.log"; die "making the performance image failed"; }
  fi
  echo "==> Running the performance pass on $(sysctl -n hw.model), $(sysctl -n hw.ncpu) cores"
  WORK="$OUT/perf-work"
  rm -rf "$WORK"
  mkdir -p "$WORK/home"
  env HOME="$WORK/home" XDG_CACHE_HOME="$WORK/cache" \
    "$OUT/glims-engine-perf" "$OUT/libglimsengine.dylib" "$WORK" "$PERF_IMAGE" 2>&1 | tee "$OUT/perf.log"
fi
