#!/usr/bin/env bash
# Builds dist/Glims.app from the SwiftPM package. Copies the committed
# Info.plist, the project LICENSE and the third-party notices into the bundle,
# signs it and verifies the signature. Fails before assembling when the
# committed notices no longer match the resolved packages.
#
#   scripts/build-app.sh [--debug]
#
# --debug builds the Debug configuration (scripts/build.sh --debug reaches this
# through lkm-build's swiftpm kind). The app builds for the host architecture
# only, because the GIMP engine it will link is built for one architecture
# (docs/plan.md).
#
# GLIMS_BUILD_DIR and GLIMS_OUTPUT_DIR override the build and output
# directories. CODE_SIGN_IDENTITY selects a signing identity; without it the
# bundle is ad-hoc signed, which runs locally but cannot be notarized.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${GLIMS_BUILD_DIR:-$PROJECT_ROOT/.build}"
OUTPUT_DIR="${GLIMS_OUTPUT_DIR:-$PROJECT_ROOT/dist}"
APP_NAME="Glims"
APP_PATH="$OUTPUT_DIR/$APP_NAME.app"

CONFIGURATION=release
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIGURATION=debug ;;
    *) echo "error: unknown option '$arg' (expected --debug)" >&2; exit 2 ;;
  esac
done

if [[ "$(uname -s)" != Darwin ]]; then
  echo "error: Glims requires macOS and AppKit." >&2
  exit 1
fi

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/module-cache"
SWIFT_ARGS=(--configuration "$CONFIGURATION" --scratch-path "$BUILD_DIR"
            --cache-path "$BUILD_DIR/package-cache" --disable-sandbox)

cd "$PROJECT_ROOT"
echo "==> Building $APP_NAME ($CONFIGURATION)"
swift build "${SWIFT_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"

echo "==> Checking third-party notices"
"$PROJECT_ROOT/scripts/third-party-notices.sh" --check "$BUILD_DIR"

echo "==> Assembling $APP_PATH"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_PATH/Contents/MacOS/$APP_NAME"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -d "$bundle" ]] && cp -R "$bundle" "$APP_PATH/Contents/Resources/"
done
cp "$PROJECT_ROOT/LICENSE" "$APP_PATH/Contents/Resources/LICENSE.txt"
cp "$PROJECT_ROOT/Resources/Third-Party-Notices.txt" "$APP_PATH/Contents/Resources/Third-Party-Notices.txt"

echo "==> Signing"
if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --sign "$CODE_SIGN_IDENTITY" "$APP_PATH"
else
  codesign --force --sign - "$APP_PATH"
fi
codesign --verify --strict --verbose=2 "$APP_PATH"
printf '\nBuilt %s\n' "$APP_PATH"
