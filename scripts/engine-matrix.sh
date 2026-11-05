#!/usr/bin/env bash
# Builds and checks engine sets the way an engine update would (AGENTS.md,
# "Updating the engine"). For each GIMP_REF it builds the engine (only
# what changed), builds the adapter and runs its conformance tests, diffs
# the adapter's GIMP interface against the pinned engine, builds the app
# with that engine bundled, and checks the bundle with the build trees
# unreadable. Prints a table and exits non-zero if any step failed; an
# interface change alone is reported but does not fail.
#
#   scripts/engine-matrix.sh [GIMP_REF ...]   # default: MATRIX_SETS in engine.env
#
# Logs and the table go to _engine/matrix/<UTC time>/, linked from
# _engine/matrix/latest. The nightly workflow
# (.github/workflows/engine-nightly.yml) runs this on a self-hosted Mac.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=engine.env
source "$ROOT/scripts/engine.env"

REFS=("$@")
if [[ ${#REFS[@]} -eq 0 ]]; then
  read -r -a REFS <<< "$MATRIX_SETS"
fi
PINNED="${ENGINE_SETS%%:*}"

STAMP="$(date -u +%Y%m%d-%H%M%S)"
OUT="$ROOT/_engine/matrix/$STAMP"
mkdir -p "$OUT"
ln -sfn "$STAMP" "$ROOT/_engine/matrix/latest"

# step NAME REF COMMAND...: runs a step with its own log; prints its result.
step() {
  local name="$1" ref="$2"
  shift 2
  if "$@" > "$OUT/$ref-$name.log" 2>&1; then
    echo "ok"
  else
    echo "FAIL"
  fi
}

summary="$OUT/summary.md"
{
  echo "| Engine | Engine build | Adapter tests | Interface vs $PINNED | App with engine | Bundle check |"
  echo "|---|---|---|---|---|---|"
} > "$summary"

failed=0
for ref in "${REFS[@]}"; do
  echo "==> $ref"
  build=$(step engine "$ref" "$ROOT/scripts/build-engine.sh" "$ref")
  tests="skipped" diff="skipped" app="skipped" bundle="skipped"
  if [[ "$build" == ok ]]; then
    tests=$(step adapter "$ref" "$ROOT/scripts/build-adapter.sh" --test "$ref")
    checks=$(grep -c '^ok' "$ROOT/_engine/adapter/$ref/test.log" 2>/dev/null || true)
    tests="$tests (${checks:-0} checks)"

    if [[ "$ref" == "$PINNED" ]]; then
      diff="(pinned)"
    elif [[ -d "$ROOT/_engine/adapter/$PINNED/obj" ]]; then
      if python3 -I "$ROOT/scripts/interface-diff.py" "$ROOT/_engine/adapter/$PINNED/obj" \
           "$ROOT/_engine/src/$PINNED/gimp" "$ROOT/_engine/src/$ref/gimp" > "$OUT/$ref-interface.log" 2>&1; then
        diff="unchanged"
      else
        diff="CHANGED (see log)"
      fi
    else
      diff="no pinned adapter build"
    fi

    if [[ "$tests" == ok* ]]; then
      # Outside _engine/, which the bundle check makes unreadable.
      app_dir="$(mktemp -d "${TMPDIR:-/tmp}/glims-matrix-app.XXXXXX")"
      app=$(step app "$ref" env GLIMS_OUTPUT_DIR="$app_dir" "$ROOT/scripts/build-app.sh" --engine "$ref")
      if [[ "$app" == ok ]]; then
        bundle=$(step bundle "$ref" "$ROOT/scripts/check-bundle.sh" "$app_dir/Glims.app")
      fi
      rm -rf "$app_dir"
    fi
  fi
  echo "| $ref | $build | $tests | $diff | $app | $bundle |" >> "$summary"
  for result in "$build" "$tests" "$app" "$bundle"; do
    [[ "$result" == FAIL* ]] && failed=1
  done
done

cat "$summary"
echo "Logs: $OUT"
exit "$failed"
