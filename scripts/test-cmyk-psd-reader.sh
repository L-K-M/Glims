#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${GLIMS_READER_TEST_OUTPUT:-$(mktemp -d /tmp/glims-cmyk-psd-reader.XXXXXX)}"
mkdir -p "$WORK"
CC="${CC:-clang}"
COMMON=(-std=c11 -Wall -Wextra -Werror -I "$ROOT/Engine" "$ROOT/Engine/cmyk-psd-reader.c" "$ROOT/Engine/tests/cmyk-psd-reader-tests.c")
"$CC" "${COMMON[@]}" -O2 -o "$WORK/optimized"
"$WORK/optimized" > "$WORK/optimized.log"
tail -1 "$WORK/optimized.log"
if [[ "${1:-}" != optimized ]]; then
  "$CC" "${COMMON[@]}" -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -o "$WORK/sanitized"
  LEAK_CHECK=1
  # Apple ASan does not provide LeakSanitizer; keep address/UB checks active.
  [[ "$(uname -s)" != Darwin ]] || LEAK_CHECK=0
  ASAN_OPTIONS="detect_leaks=$LEAK_CHECK" "$WORK/sanitized" > "$WORK/sanitized.log"
  tail -1 "$WORK/sanitized.log"
fi
printf 'Evidence: %s\n' "$WORK"
