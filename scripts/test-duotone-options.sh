#!/usr/bin/env bash
# Bounded Photoshop .ADO settings checks; no engine or GUI required.
set -euo pipefail
case "${1:-all}" in
  all) modes=(optimized sanitized) ;;
  optimized|sanitized) modes=("$1") ;;
  *) echo "Usage: $0 [all|optimized|sanitized]" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then echo "Usage: $0 [all|optimized|sanitized]" >&2; exit 2; fi
compiler=(clang)
if [[ "$(uname -s)" == Darwin ]]; then compiler=(xcrun clang); fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/glims-duotone-options.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
run_bounded() {
  python3 - "$@" <<'PY'
import os
import signal
import subprocess
import sys
print('+ ' + ' '.join(sys.argv[1:]), flush=True)
process = subprocess.Popen(sys.argv[1:], start_new_session=True)
def stop_group():
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()

def interrupted(signum, frame):
    stop_group()
    raise SystemExit(128 + signum)

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGHUP, interrupted)
try:
    result = process.wait(timeout=60)
except subprocess.TimeoutExpired:
    print('Duotone options check exceeded 60 seconds', file=sys.stderr, flush=True)
    stop_group()
    raise SystemExit(124)
except KeyboardInterrupt:
    stop_group()
    raise
raise SystemExit(result)
PY
}
for mode in "${modes[@]}"; do
  flags=(-O2)
  if [[ "$mode" == sanitized ]]; then flags=(-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer); fi
  run_bounded "${compiler[@]}" -std=c11 -Wall -Wextra -Werror -pedantic "${flags[@]}" \
    -I"$ROOT/Engine" "$ROOT/Engine/duotone-options.c" "$ROOT/Engine/tests/duotone-options-tests.c" -o "$WORK/$mode"
  run_bounded "$WORK/$mode" "$ROOT/Engine/tests/fixtures/photoshop-cc2018-duotone.psd"
done
