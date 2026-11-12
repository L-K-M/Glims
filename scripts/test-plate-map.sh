#!/usr/bin/env bash
# Pure metadata contract checks; no engine install or GUI is needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/glims-plate-map.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
for mode in optimized sanitized; do
  flags=(-O2)
  if [[ "$mode" == sanitized ]]; then
    flags=(-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer)
  fi
  xcrun clang -std=c11 -Wall -Wextra -Werror -pedantic "${flags[@]}" \
    -I"$ROOT/Engine" "$ROOT/Engine/plate-map.c" "$ROOT/Engine/tests/plate-map-tests.c" \
    -o "$WORK/$mode"
  "$WORK/$mode"
done
