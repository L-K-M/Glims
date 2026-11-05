#!/usr/bin/env bash
# Builds dist/Glims.app from the SwiftPM package. Copies the committed
# Info.plist, icon, the project LICENSE and the third-party notices into the bundle,
# signs it and verifies the signature. Fails before assembling when the
# committed notices no longer match the resolved packages.
#
#   scripts/build-app.sh [--debug] [--engine GIMP_REF]
#
# --engine bundles a built engine set (scripts/build-engine.sh and
# scripts/build-adapter.sh GIMP_REF) into the app with
# scripts/bundle-engine.py, so it runs on its own; scripts/check-bundle.sh
# tests that. Without it the app has no engine and looks for one through
# GLIMS_ENGINE_LIBRARY (Sources/GlimsKit/Engine/EngineLibrary.swift).
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
ENGINE_REF=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) CONFIGURATION=debug ;;
    --engine)
      [[ $# -ge 2 ]] || { echo "error: --engine needs a GIMP_REF" >&2; exit 2; }
      ENGINE_REF="$2"; shift ;;
    *) echo "error: unknown option '$1' (expected --debug or --engine GIMP_REF)" >&2; exit 2 ;;
  esac
  shift
done

if [[ -n "$ENGINE_REF" ]]; then
  ENGINE_INSTALL="$PROJECT_ROOT/_engine/install/$ENGINE_REF"
  ENGINE_ADAPTER="$PROJECT_ROOT/_engine/adapter/$ENGINE_REF/libglimsengine.dylib"
  DEPS_PREFIX="$PROJECT_ROOT/_deps/macports"
  [[ -d "$ENGINE_INSTALL" ]] || { echo "error: no engine at $ENGINE_INSTALL; run scripts/build-engine.sh $ENGINE_REF" >&2; exit 1; }
  [[ -f "$ENGINE_ADAPTER" ]] || { echo "error: no adapter at $ENGINE_ADAPTER; run scripts/build-adapter.sh $ENGINE_REF" >&2; exit 1; }
fi

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
cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -d "$bundle" ]] && cp -R "$bundle" "$APP_PATH/Contents/Resources/"
done
cp "$PROJECT_ROOT/LICENSE" "$APP_PATH/Contents/Resources/LICENSE.txt"
cp "$PROJECT_ROOT/Resources/Third-Party-Notices.txt" "$APP_PATH/Contents/Resources/Third-Party-Notices.txt"

if [[ -n "$ENGINE_REF" ]]; then
  echo "==> Bundling the engine ($ENGINE_REF)"
  python3 -I "$PROJECT_ROOT/scripts/bundle-engine.py" "$APP_PATH" "$ENGINE_INSTALL" "$DEPS_PREFIX" \
    "$ENGINE_ADAPTER" "$PROJECT_ROOT/_engine/src/$ENGINE_REF"
fi

echo "==> Signing"
if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --sign "$CODE_SIGN_IDENTITY" "$APP_PATH"
else
  codesign --force --sign - "$APP_PATH"
fi
codesign --verify --strict --verbose=2 "$APP_PATH"
printf '\nBuilt %s\n' "$APP_PATH"
