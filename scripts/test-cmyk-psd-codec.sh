#!/usr/bin/env bash
# Pure native-CMYK PSD serializer checks; no engine install or GUI is needed.
set -euo pipefail
case "${1:-all}" in
  all) modes=(optimized sanitized) ;;
  optimized|sanitized) modes=("$1") ;;
  *) echo "Usage: $0 [all|optimized|sanitized]" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [all|optimized|sanitized]" >&2
  exit 2
fi
compiler=(clang)
if [[ "$(uname -s)" == Darwin ]]; then compiler=(xcrun clang); fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/glims-cmyk-psd.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
run_bounded() {
  python3 - "$@" <<'PY'
import subprocess
import sys
print('+ ' + ' '.join(sys.argv[1:]), flush=True)
try:
    result = subprocess.run(sys.argv[1:], timeout=60)
except subprocess.TimeoutExpired:
    print('CMYK PSD serializer check exceeded 60 seconds', file=sys.stderr, flush=True)
    raise SystemExit(124)
raise SystemExit(result.returncode)
PY
}
for mode in "${modes[@]}"; do
  flags=(-O2)
  if [[ "$mode" == sanitized ]]; then
    flags=(-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
  fi
  run_bounded "${compiler[@]}" -std=c11 -Wall -Wextra -Werror -pedantic "${flags[@]}" \
    -I"$ROOT/Engine" "$ROOT/Engine/cmyk-psd-codec.c" "$ROOT/Engine/tests/cmyk-psd-codec-tests.c" \
    -o "$WORK/$mode"
  run_bounded "$WORK/$mode"
done
