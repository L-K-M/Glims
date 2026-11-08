#!/usr/bin/env bash
# An older adapter must be refused before the conformance runner calls
# beyond its advertised table. No engine install or GUI is needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/glims-test-abi.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/stub.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include "glims_engine.h"
static GlimsStatus unexpected_start(const GlimsEngineConfig *config, GlimsEngine **engine, char **error)
{
  (void)config; (void)error;
  *engine = NULL;
  puts("UNEXPECTED_START_AFTER_ABI_REFUSAL");
  return GLIMS_STATUS_NOT_RUNNING;
}
static void release_string(char *text) { free(text); }
/* Allocate the complete object so a broken runner remains safe in this
 * regression; advertise only the fixed metadata prefix, without start. */
static const GlimsEngineAPI api = { .api_version = GLIMS_ENGINE_API_VERSION,
                                    .struct_size = 8, .start = unexpected_start,
                                    .free_string = release_string };
const GlimsEngineAPI *glims_engine_get_api(uint32_t version)
{
  return version == GLIMS_ENGINE_API_VERSION ? &api : NULL;
}
C
xcrun clang -std=c11 -Wall -Wextra -Werror -dynamiclib -I"$ROOT/Sources/CGlimsEngine/include" \
  "$WORK/stub.c" -o "$WORK/stub.dylib"
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -I"$ROOT/Sources/CGlimsEngine/include" \
  "$ROOT/Engine/tests/engine-tests.c" -o "$WORK/tests"
result=0
"$WORK/tests" "$WORK/stub.dylib" "$WORK" "$ROOT/Engine/tests/fixtures" > "$WORK/output" 2>&1 || result=$?
if [[ "$result" != 1 ]] || ! grep -q '^FAIL.*library serves facade version' "$WORK/output" || \
   grep -q 'UNEXPECTED_START_AFTER_ABI_REFUSAL' "$WORK/output"; then
  cat "$WORK/output"
  echo "error: the runner did not stop after rejecting the adapter table" >&2
  exit 1
fi
echo "Conformance runner refuses an older table before calling engine functions."
