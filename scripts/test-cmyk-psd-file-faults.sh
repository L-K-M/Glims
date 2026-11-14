#!/usr/bin/env bash
# Syscall fault injection for the pure C file transaction; no engine or GUI.
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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/glims-cmyk-psd-file-faults.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
run_bounded() {
  python3 - "$@" <<'PY'
import os
import signal
import subprocess
import sys
print('+ ' + ' '.join(sys.argv[1:]), flush=True)
p = subprocess.Popen(sys.argv[1:], start_new_session=True)
try:
    code = p.wait(timeout=60)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGTERM)
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
    print('CMYK PSD file fault check exceeded 60 seconds', file=sys.stderr)
    raise SystemExit(124)
raise SystemExit(code if code >= 0 else 128 - code)
PY
}
aliases=(-Dfsync=glims_test_fsync -Dclose=glims_test_close
         -Drenameat=glims_test_renameat -Dfchmod=glims_test_fchmod
         -Dwrite=glims_test_write -Dunlinkat=glims_test_unlinkat)
for mode in "${modes[@]}"; do
  flags=(-O2)
  if [[ "$mode" == sanitized ]]; then
    flags=(-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
  fi
  common=(-std=c11 -Wall -Wextra -Werror -pedantic "${flags[@]}" -I"$ROOT/Engine")
  run_bounded "${compiler[@]}" "${common[@]}" -c "$ROOT/Engine/cmyk-psd-codec.c" -o "$WORK/codec-$mode.o"
  run_bounded "${compiler[@]}" "${common[@]}" -c "$ROOT/Engine/bitmap-psd-codec.c" -o "$WORK/bitmap-$mode.o"
  run_bounded "${compiler[@]}" "${common[@]}" -c "$ROOT/Engine/duotone-psd-codec.c" -o "$WORK/duotone-$mode.o"
  run_bounded "${compiler[@]}" "${common[@]}" "${aliases[@]}" \
    -c "$ROOT/Engine/cmyk-psd-file.c" -o "$WORK/file-$mode.o"
  run_bounded "${compiler[@]}" "${common[@]}" \
    -c "$ROOT/Engine/tests/cmyk-psd-file-fault-tests.c" -o "$WORK/tests-$mode.o"
  run_bounded "${compiler[@]}" "${flags[@]}" "$WORK/codec-$mode.o" \
    "$WORK/file-$mode.o" "$WORK/bitmap-$mode.o" "$WORK/duotone-$mode.o" "$WORK/tests-$mode.o" -o "$WORK/$mode"
  run_bounded "$WORK/$mode"
done
