#!/usr/bin/env bash
# Builds dist/Glims.app from the SwiftPM package. Copies the committed
# Info.plist, icon, the project LICENSE and the third-party notices into the bundle,
# signs it and verifies the signature. Fails before assembling when the
# committed notices no longer match the resolved packages.
#
#   scripts/build-app.sh [--debug] [--engine GIMP_REF | --shell-only]
#
# Normal builds bundle the pinned engine. --engine selects another built
# engine set; --shell-only explicitly builds the interface for hosted CI or
# development with GLIMS_ENGINE_LIBRARY. Never distribute a shell-only build.
#
# --debug builds the Debug configuration (scripts/build.sh --debug reaches this
# through lkm-build's swiftpm kind). The app builds for the host architecture
# only, because the GIMP engine it will link is built for one architecture
# (docs/plan.md).
#
# GLIMS_BUILD_DIR and GLIMS_OUTPUT_DIR override the build and output
# directories. GLIMS_ADAPTER_ROOT selects an absolute adapter output directory
# shared with build-adapter.sh and check-bundle.sh, useful for worktrees.
# CODE_SIGN_IDENTITY selects a signing identity; without it the
# bundle is ad-hoc signed, which runs locally but cannot be notarized.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${GLIMS_BUILD_DIR:-$PROJECT_ROOT/.build}"
OUTPUT_DIR="${GLIMS_OUTPUT_DIR:-$PROJECT_ROOT/dist}"
APP_NAME="Glims"
FINAL_APP_PATH="$OUTPUT_DIR/$APP_NAME.app"

CONFIGURATION=release
source "$PROJECT_ROOT/scripts/engine.env"
ENGINE_REF="${ENGINE_SETS%%:*}"
ENGINE_OPTION_SET=false
SHELL_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) CONFIGURATION=debug ;;
    --engine)
      [[ $# -ge 2 ]] || { echo "error: --engine needs a GIMP_REF" >&2; exit 2; }
      [[ "$SHELL_ONLY" == false ]] || { echo "error: --engine and --shell-only cannot be combined" >&2; exit 2; }
      ENGINE_REF="$2"; ENGINE_OPTION_SET=true; shift ;;
    --shell-only)
      [[ "$ENGINE_OPTION_SET" == false ]] || { echo "error: --engine and --shell-only cannot be combined" >&2; exit 2; }
      SHELL_ONLY=true ;;
    *) echo "error: unknown option '$1' (expected --debug, --engine GIMP_REF or --shell-only)" >&2; exit 2 ;;
  esac
  shift
done

if [[ "$SHELL_ONLY" == false ]]; then
  ENGINE_INSTALL="$PROJECT_ROOT/_engine/install/$ENGINE_REF"
  ADAPTER_ROOT="${GLIMS_ADAPTER_ROOT:-$PROJECT_ROOT/_engine/adapter}"
  [[ "$ADAPTER_ROOT" == /* ]] || { echo "error: GLIMS_ADAPTER_ROOT must be an absolute directory." >&2; exit 2; }
  ENGINE_ADAPTER="$ADAPTER_ROOT/$ENGINE_REF/libglimsengine.dylib"
  DEPS_PREFIX="$PROJECT_ROOT/_deps/macports"
  [[ -d "$ENGINE_INSTALL" ]] || {
    echo "error: Glims needs its image engine. Run scripts/bootstrap-deps.sh, scripts/build-engine.sh $ENGINE_REF and scripts/build-adapter.sh $ENGINE_REF, then build again." >&2
    echo "For interface-only development, use scripts/build-app.sh --shell-only." >&2
    exit 1
  }
  [[ -f "$ENGINE_ADAPTER" ]] || { echo "error: no adapter at $ENGINE_ADAPTER; run scripts/build-adapter.sh $ENGINE_REF" >&2; exit 1; }
fi

if [[ "$(uname -s)" != Darwin ]]; then
  echo "error: Glims requires macOS and AppKit." >&2
  exit 1
fi

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
ASSEMBLY_LOCK="$OUTPUT_DIR/.glims-assemble.lock"
mkdir "$ASSEMBLY_LOCK" 2>/dev/null || {
  echo "error: another app build holds $ASSEMBLY_LOCK" >&2
  exit 1
}
STAGE_DIR=""
cleanup() {
  [[ -z "$STAGE_DIR" ]] || rm -rf "$STAGE_DIR"
  rmdir "$ASSEMBLY_LOCK"
}
trap cleanup EXIT
STAGE_DIR="$(mktemp -d "$OUTPUT_DIR/.glims-build.XXXXXX")"
APP_PATH="$STAGE_DIR/$APP_NAME.app"
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

echo "==> Assembling $FINAL_APP_PATH"
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

if [[ "$SHELL_ONLY" == false ]]; then
  echo "==> Building the current engine adapter ($ENGINE_REF)"
  "$PROJECT_ROOT/scripts/build-adapter.sh" "$ENGINE_REF"
  echo "==> Bundling the engine ($ENGINE_REF)"
  xcrun clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 -I"$DEPS_PREFIX/include" \
    "$PROJECT_ROOT/Engine/helpers/font-cache.c" "$DEPS_PREFIX/lib/libfontconfig.dylib" \
    "$DEPS_PREFIX/lib/libharfbuzz.dylib" -framework CoreText -framework CoreFoundation \
    -o "$APP_PATH/Contents/MacOS/glims-font-cache"
  python3 -I "$PROJECT_ROOT/scripts/bundle-engine.py" "$APP_PATH" "$ENGINE_INSTALL" "$DEPS_PREFIX" \
    "$ENGINE_ADAPTER" "$PROJECT_ROOT/_engine/src/$ENGINE_REF"
  echo "==> Preparing first-launch command registry"
  python3 -I "$PROJECT_ROOT/scripts/prepare-engine-startup.py" "$APP_PATH"
fi

echo "==> Signing"
if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --sign "$CODE_SIGN_IDENTITY" "$APP_PATH"
else
  codesign --force --sign - "$APP_PATH"
fi
# Copied sources can already be owner-only, and signing creates new files.
# Normalize the finished bundle for other users without following its symlinks
# or changing the private staging directory that contains it.
find "$APP_PATH" -type d -exec chmod a+rx,go-w {} +
find "$APP_PATH" -type f -exec chmod a+rX,go-w {} +
codesign --verify --strict --verbose=2 "$APP_PATH"
# Publish only a signed, complete app. Finder or a running plug-in can
# write caches in the old bundle, so deleting it in place is unreliable.
PREVIOUS_APP="$STAGE_DIR/previous.app"
if [[ -e "$FINAL_APP_PATH" ]]; then mv "$FINAL_APP_PATH" "$PREVIOUS_APP"; fi
if ! mv "$APP_PATH" "$FINAL_APP_PATH"; then
  [[ ! -e "$PREVIOUS_APP" ]] || mv "$PREVIOUS_APP" "$FINAL_APP_PATH"
  exit 1
fi
printf '\nBuilt %s\n' "$FINAL_APP_PATH"
