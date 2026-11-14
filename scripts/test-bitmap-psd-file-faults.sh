#!/usr/bin/env bash
# Inject destination failures into the shared transaction through Bitmap's API.
set -euo pipefail
case "${1:-all}" in
  all) modes=(optimized sanitized) ;;
  optimized|sanitized) modes=("$1") ;;
  *) echo "Usage: $0 [all|optimized|sanitized]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || exit 2
compiler=(clang)
if [[ "$(uname -s)" == Darwin ]]; then compiler=(xcrun clang); fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/glims-bitmap-psd-faults.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
for mode in "${modes[@]}"; do
  flags=(-O2)
  if [[ "$mode" == sanitized ]]; then flags=(-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer); fi
  common=(-std=c11 -Wall -Wextra -Werror -pedantic "${flags[@]}" -I"$ROOT/Engine")
  "${compiler[@]}" "${common[@]}" -Dwrite=glims_test_write -Dfsync=glims_test_fsync -Drenameat=glims_test_renameat \
    -c "$ROOT/Engine/cmyk-psd-file.c" -o "$WORK/file.o"
  "${compiler[@]}" "${common[@]}" "$ROOT/Engine/cmyk-psd-codec.c" "$ROOT/Engine/bitmap-psd-codec.c" \
    "$ROOT/Engine/tests/bitmap-psd-file-fault-tests.c" "$WORK/file.o" -o "$WORK/test"
  python3 - "$WORK/test" <<'PY'
import subprocess, sys
try:
    result = subprocess.run([sys.argv[1]], timeout=60)
except subprocess.TimeoutExpired:
    raise SystemExit('Bitmap PSD fault checks exceeded 60 seconds')
raise SystemExit(result.returncode)
PY
done
