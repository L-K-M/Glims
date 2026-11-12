#!/usr/bin/env bash
# Pure metadata contract checks; no engine install or GUI is needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/glims-plate-map.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
run_bounded() {
  python3 - "$@" <<'PY'
import subprocess
import sys
print('+ ' + ' '.join(sys.argv[1:]), flush=True)
try:
    result = subprocess.run(sys.argv[1:], timeout=60)
except subprocess.TimeoutExpired:
    print('Component metadata check exceeded 60 seconds', file=sys.stderr, flush=True)
    raise SystemExit(124)
raise SystemExit(result.returncode)
PY
}
for mode in optimized sanitized; do
  flags=(-O2)
  if [[ "$mode" == sanitized ]]; then
    flags=(-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer)
  fi
  run_bounded xcrun clang -std=c11 -Wall -Wextra -Werror -pedantic "${flags[@]}" \
    -I"$ROOT/Engine" "$ROOT/Engine/plate-map.c" "$ROOT/Engine/tests/plate-map-tests.c" \
    -o "$WORK/$mode"
  run_bounded "$WORK/$mode"
done
