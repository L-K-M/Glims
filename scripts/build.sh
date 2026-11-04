#!/usr/bin/env bash
# Builds Glims.app from the command line and reveals it in Finder on success.
# Incremental Release build by default; --clean wipes .build/ and dist/ before
# building (never the engine trees in _engine/ and _deps/). The swiftpm kind
# delegates the build, bundle assembly, notices check and signing to
# scripts/build-app.sh.
#
# Usage: scripts/build.sh [--clean] [--debug] [--run] [--install] [--zip] [--dmg]
# Shared engine: https://github.com/L-K-M/release-tool (this stub only sets config).
set -euo pipefail
export BUILD_APP_NAME="Glims"
export BUILD_KIND="swiftpm"
export BUILD_SWIFTPM_ASSEMBLE="scripts/build-app.sh"
export BUILD_PRODUCT_PATH="dist/Glims.app"
export BUILD_CLEAN_PATHS=".build dist"
export BUILD_INVOKED_AS="scripts/build.sh"
BIN="${LKM_BUILD_BIN:-lkm-build}"
command -v "$BIN" >/dev/null 2>&1 || {
  echo "error: lkm-build not found — clone https://github.com/L-K-M/release-tool and run ./install.sh" >&2
  exit 1
}
exec "$BIN" "$@"
