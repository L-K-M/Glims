#!/usr/bin/env bash
# Regenerates Resources/Third-Party-Notices.txt from the Swift packages pinned
# in Package.resolved, using swiftpm-notices.py (shared with RelayBar) and the
# overrides in third-party-notices.json. With --check it writes nothing and
# fails when the committed file differs; build-app.sh and CI run that.
#
# The notices cover the Swift packages only. When the GIMP engine and its
# dependencies are bundled (docs/plan.md), their notices must be added here
# before any build that ships them.
#
# Usage: scripts/third-party-notices.sh [--check] [BUILD_DIR]
#   BUILD_DIR is the SwiftPM scratch path holding checkouts/ (default .build);
#   resolve packages first (swift package resolve, or any swift build).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE=(--output)
if [[ "${1:-}" == "--check" ]]; then
  MODE=(--quiet --check)
  shift
fi

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [--check] [BUILD_DIR]" >&2
  exit 2
fi

python3 -I "$ROOT/scripts/swiftpm-notices.py" \
  --title "Glims" \
  --resolved "$ROOT/Package.resolved" \
  --checkouts "${1:-$ROOT/.build}" \
  --overrides "$ROOT/scripts/third-party-notices.json" \
  "${MODE[@]}" "$ROOT/Resources/Third-Party-Notices.txt"
