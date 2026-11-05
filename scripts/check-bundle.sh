#!/usr/bin/env bash
# Checks that an app bundle with an engine (scripts/build-app.sh --engine)
# runs on its own: the conformance tests against the bundled adapter and the
# app's --engine-smoke-test run under a sandbox profile that denies every
# read of _engine/ and _deps/, as on a Mac without the build trees.
#
#   scripts/check-bundle.sh [APP]   # default: dist/Glims.app
#
# Writes only to a temporary folder; HOME points there too.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Glims.app}"
ADAPTER="$APP/Contents/Frameworks/libglimsengine.dylib"
[[ -f "$ADAPTER" ]] || { echo "error: $APP has no engine; build it with scripts/build-app.sh --engine GIMP_REF" >&2; exit 1; }
case "$(cd "$APP" && pwd -P)/" in
  "$ROOT/_engine/"*|"$ROOT/_deps/"*) echo "error: $APP is inside a build tree the check makes unreadable" >&2; exit 1 ;;
esac

TESTS="$(ls -t "$ROOT"/_engine/adapter/*/glims-engine-tests 2>/dev/null | head -1)"
[[ -n "$TESTS" ]] || { echo "error: no conformance test binary; run scripts/build-adapter.sh first" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/glims-check-bundle.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home" "$WORK/tests"
# The test binary lives in _engine/; run a copy so the sandbox can deny it.
cp "$TESTS" "$WORK/glims-engine-tests"

PROFILE="(version 1)
(allow default)
(deny file-read* file-write* (subpath \"$ROOT/_engine\") (subpath \"$ROOT/_deps\"))"

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
