#!/usr/bin/env bash
# Checks that an app bundle with an engine (scripts/build-app.sh --engine)
# runs on its own: the conformance tests against the bundled adapter and the
# app's --engine-smoke-test run under a sandbox profile that denies every
# read of _engine/, _deps/ and Swift build outputs, as on a Mac without
# the build trees. SwiftPM resource bundles must resolve inside the app.
#
#   scripts/check-bundle.sh [APP]   # default: dist/Glims.app
#
# Writes only to a temporary folder; HOME points there too.
# GLIMS_ADAPTER_ROOT selects the matching conformance runner when the app was
# built with isolated adapter outputs; use the same value for both commands.
# GLIMS_BUILD_DIR likewise identifies a custom Swift build directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Glims.app}"
ADAPTER="$APP/Contents/Frameworks/libglimsengine.dylib"
[[ -f "$ADAPTER" ]] || { echo "error: $APP has no engine; build it with scripts/build-app.sh --engine GIMP_REF" >&2; exit 1; }
ADAPTER_ROOT="${GLIMS_ADAPTER_ROOT:-$ROOT/_engine/adapter}"
[[ "$ADAPTER_ROOT" == /* ]] || { echo "error: GLIMS_ADAPTER_ROOT must be an absolute directory." >&2; exit 2; }
# Resolve shared worktree symlinks and escape profile strings. Isolated
# adapter outputs are development inputs too, and must stay inaccessible.
PROFILE="$(python3 - "$APP" "$ROOT/_engine" "$ROOT/_deps" "$ADAPTER_ROOT" "$ROOT/.build" "${GLIMS_BUILD_DIR:-$ROOT/.build}" <<'PY_PROFILE'
import json
from pathlib import Path
import sys
app = Path(sys.argv[1]).resolve()
inputs = [Path(path).resolve() for path in sys.argv[2:]]
if any(app.is_relative_to(path) for path in inputs):
    sys.exit("error: the app is inside a build tree the check makes unreadable")
subpaths = " ".join("(subpath " + json.dumps(str(path), ensure_ascii=False) + ")" for path in inputs)
print("(version 1)\n(allow default)\n(deny file-read* file-write* " + subpaths + ")")
PY_PROFILE
)"

TESTS="$(ls -t "$ADAPTER_ROOT"/*/glims-engine-tests 2>/dev/null | head -1)"
[[ -n "$TESTS" ]] || { echo "error: no conformance test binary; run scripts/build-adapter.sh first" >&2; exit 1; }
DUOTONE_TESTS="$(dirname "$TESTS")/glims-duotone-preservation-tests"
[[ -x "$DUOTONE_TESTS" ]] || { echo "error: no matching Duotone test binary; run scripts/build-adapter.sh first" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/glims-check-bundle.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home" "$WORK/tests"
# The test binary lives in _engine/; run a copy so the sandbox can deny it.
cp "$TESTS" "$WORK/glims-engine-tests"
cp "$DUOTONE_TESTS" "$WORK/glims-duotone-preservation-tests"
mkdir -p "$WORK/duotone/home" "$WORK/duotone/cache"


status=0
echo "==> Conformance tests against the bundled adapter (build trees unreadable)"
if sandbox-exec -p "$PROFILE" env HOME="$WORK/home" TMPDIR="$WORK" \
     "$WORK/glims-engine-tests" "$ADAPTER" "$WORK/tests" "$ROOT/Engine/tests/fixtures" > "$WORK/tests.log" 2>&1; then
  echo "-- $(grep -c '^ok' "$WORK/tests.log") checks passed"
else
  grep -E '^FAIL' "$WORK/tests.log" || tail -20 "$WORK/tests.log"
  echo "!! the conformance tests failed against the bundle"
  status=1
fi
if grep -q -E "$ROOT/_(engine|deps)" "$WORK/tests.log"; then
  echo "!! the engine still looked for files in the build trees:"
  grep -E "$ROOT/_(engine|deps)" "$WORK/tests.log" | head -5
  status=1
fi

echo "==> Duotone preservation against the bundled adapter (build trees unreadable)"
if sandbox-exec -p "$PROFILE" env HOME="$WORK/duotone/home" XDG_CACHE_HOME="$WORK/duotone/cache" TMPDIR="$WORK" \
     "$WORK/glims-duotone-preservation-tests" "$ADAPTER" "$WORK/duotone" "$ROOT/Engine/tests/fixtures" > "$WORK/duotone.log" 2>&1; then
  echo "-- $(grep -c '^ok' "$WORK/duotone.log") checks passed"
else
  grep -E '^FAIL' "$WORK/duotone.log" || tail -20 "$WORK/duotone.log"
  echo "!! the Duotone preservation checks failed against the bundle"
  status=1
fi
if grep -q -E "$ROOT/_(engine|deps)" "$WORK/duotone.log"; then
  echo "!! Duotone preservation looked for files in the build trees"
  status=1
fi

echo "==> The app's engine smoke test (build trees unreadable)"
if sandbox-exec -p "$PROFILE" env -u GLIMS_ENGINE_LIBRARY HOME="$WORK/home" TMPDIR="$WORK" \
     "$APP/Contents/MacOS/Glims" --engine-smoke-test > "$WORK/smoke.log" 2>&1; then
  echo "-- $(grep -c '^ok' "$WORK/smoke.log") checks passed"
else
  grep -E '^FAIL' "$WORK/smoke.log" || tail -20 "$WORK/smoke.log"
  echo "!! the app's engine smoke test failed against the bundle"
  status=1
fi

exit "$status"
