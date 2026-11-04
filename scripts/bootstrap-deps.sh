#!/usr/bin/env bash
# Builds the dependency prefix for GIMP's engine: MacPorts base from source in
# _deps/macports (no root privileges), then every port GIMP's own macOS build
# lists in build/macos/all-deps-uni.txt, for each ref in scripts/engine.env.
#
#   scripts/bootstrap-deps.sh            # install or update everything (hours on first run)
#   scripts/bootstrap-deps.sh --check    # print the resolved configuration; change nothing
#   scripts/bootstrap-deps.sh --macports-only   # stop after MacPorts base and the ports tree
#
# A non-default prefix cannot use MacPorts' binary archives, so every port
# builds from source; the first run takes hours. Reruns are incremental:
# installed ports are skipped. Logs go to _deps/logs/.
#
# This mirrors upstream's build/macos/1_build-deps-macports.sh for a
# non-default prefix without running it: that script can `git apply` patches
# to a GIMP checkout, which the zero-patch rule forbids (AGENTS.md). GIMP's
# sources are only read here, through a bare blobless mirror in
# _engine/gimp.git.
#
# Requires macOS with the Xcode command line tools, git, curl and network
# access to GitHub, gitlab.gnome.org and the MacPorts rsync mirrors.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=engine.env
source "$ROOT/scripts/engine.env"

DEPS_DIR="$ROOT/_deps"
PREFIX="$DEPS_DIR/macports"
PORT="$PREFIX/bin/port"
GIMP_MIRROR="$ROOT/_engine/gimp.git"
LISTS_DIR="$DEPS_DIR/lists"
TARBALL="$DEPS_DIR/downloads/MacPorts-$MACPORTS_VERSION.tar.bz2"
TARBALL_URL="https://github.com/macports/macports-base/releases/download/v$MACPORTS_VERSION/MacPorts-$MACPORTS_VERSION.tar.bz2"
# MacPorts must not see Homebrew or other user tools while it builds.
CLEAN_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

MODE=all
for arg in "$@"; do
  case "$arg" in
    --check|--macports-only)
      [[ "$MODE" == all ]] || { echo "!! --check and --macports-only cannot be combined" >&2; exit 2; }
      MODE="${arg#--}" ;;
    -h|--help) awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) echo "!! unknown option '$arg' (see --help)" >&2; exit 2 ;;
  esac
done

die() { echo "!! $*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "the engine dependencies build on macOS only."
ARCH="$(uname -m)"
PLIST_TARGET="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Resources/Info.plist")" ||
  die "cannot read LSMinimumSystemVersion from Resources/Info.plist."
[[ "$PLIST_TARGET" == "$DEPLOYMENT_TARGET" ]] ||
  die "DEPLOYMENT_TARGET ($DEPLOYMENT_TARGET) in scripts/engine.env differs from LSMinimumSystemVersion ($PLIST_TARGET)."

if [[ "$MODE" == check ]]; then
  echo "bootstrap-deps --check"
  echo "  prefix:             $PREFIX"
  echo "  MacPorts:           $MACPORTS_VERSION ($( [[ -x "$PORT" ]] && "$PORT" version 2>/dev/null | sed -n 's/^Version: */installed /p' || echo 'not installed'))"
  echo "  build arch:         $ARCH"
  echo "  deployment target:  $DEPLOYMENT_TARGET"
  echo "  GIMP mirror:        $GIMP_MIRROR ($( [[ -d "$GIMP_MIRROR" ]] && echo present || echo 'not cloned'))"
  echo "  GIMP refs:          $GIMP_REFS"
  exit 0
fi

xcode-select -p >/dev/null 2>&1 || die "install the Xcode command line tools first (xcode-select --install)."
mkdir -p "$DEPS_DIR/downloads" "$DEPS_DIR/src" "$DEPS_DIR/logs" "$LISTS_DIR" "$ROOT/_engine"

# --- GIMP's dependency lists, read from a bare mirror ----------------------------
echo "==> Updating the GIMP mirror"
if [[ ! -d "$GIMP_MIRROR" ]]; then
  git clone --quiet --bare --filter=blob:none "$GIMP_REPO" "$GIMP_MIRROR"
fi
# A bare clone has no fetch refspec; without one, fetch would leave branches
# such as master stale while tags update.
git -C "$GIMP_MIRROR" remote set-url origin "$GIMP_REPO"
git -C "$GIMP_MIRROR" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
git -C "$GIMP_MIRROR" fetch --quiet --tags --prune origin

for ref in $GIMP_REFS; do
  list="$LISTS_DIR/$ref.txt"
  git -C "$GIMP_MIRROR" show "$ref:build/macos/all-deps-uni.txt" > "$list.raw" ||
    die "$ref has no build/macos/all-deps-uni.txt."
  # The same transformation upstream applies: drop comments and the Homebrew
  # alternatives, keep port names with their +/- variants.
  { grep -v '^#' "$list.raw" || true; } | sed 's/#.*//' | sed 's/|homebrew:[^ ]*//g' | tr -d '\\' | xargs > "$list"
  [[ -s "$list" ]] || die "$ref lists no ports in build/macos/all-deps-uni.txt."
  rm -f "$list.raw"
  echo "-- $ref: $(tr ' ' '\n' < "$list" | grep -cv '^[+-]') ports"
done

# --- MacPorts base -------------------------------------------------------------
installed_version=""
if [[ -x "$PORT" ]]; then
  installed_version="$("$PORT" version 2>/dev/null | sed -n 's/^Version: *//p' || true)"
  [[ -n "$installed_version" ]] || die "$PORT exists but does not run; a MacPorts base install in $PREFIX is broken. Move it aside and rerun."
fi
if [[ "$installed_version" == "$MACPORTS_VERSION" ]]; then
  echo ".. MacPorts $MACPORTS_VERSION already installed in $PREFIX"
else
  [[ -z "$installed_version" ]] || die "$PREFIX holds MacPorts $installed_version, not $MACPORTS_VERSION; move it aside first."
  echo "==> Installing MacPorts $MACPORTS_VERSION into $PREFIX"
  if [[ ! -f "$TARBALL" ]]; then
    curl -fsSL --retry 3 -o "$TARBALL.part" "$TARBALL_URL"
    mv "$TARBALL.part" "$TARBALL"
  fi
  actual="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
  if [[ "$actual" != "$MACPORTS_SHA256" ]]; then
    rm -f "$TARBALL"
    die "checksum mismatch for the MacPorts tarball ($actual); the file was removed, rerun to download it again."
  fi
  src="$DEPS_DIR/src/MacPorts-$MACPORTS_VERSION"
  rm -rf "$src"
  tar -xjf "$TARBALL" -C "$DEPS_DIR/src"
  (
    cd "$src"
    env PATH="$CLEAN_PATH" ./configure --quiet \
      --prefix="$PREFIX" \
      --with-applications-dir="$PREFIX/Applications" \
      --with-no-root-privileges \
      --without-startupitems
    env PATH="$CLEAN_PATH" make -j"$(sysctl -n hw.ncpu)"
    env PATH="$CLEAN_PATH" make install
  ) > "$DEPS_DIR/logs/macports-base.log" 2>&1 || die "MacPorts base failed; see $DEPS_DIR/logs/macports-base.log"
fi

# --- macports.conf -------------------------------------------------------------
CONF="$PREFIX/etc/macports/macports.conf"
set_conf() {
  local key="$1" value="$2"
  if grep -qE "^#?[[:space:]]*$key[[:space:]]" "$CONF"; then
    /usr/bin/sed -i '' -E "s|^#?[[:space:]]*$key[[:space:]].*|$key $value|" "$CONF"
  else
    printf '%s %s\n' "$key" "$value" >> "$CONF"
  fi
  return 0
}
set_conf build_arch "$ARCH"
set_conf macosx_deployment_target "$DEPLOYMENT_TARGET"
# Binary archives only match /opt/local; skip the futile archive lookups.
set_conf buildfromsource always

# --- Ports tree ----------------------------------------------------------------
echo "==> Syncing the ports tree"
env PATH="$PREFIX/bin:$CLEAN_PATH" "$PORT" -N sync > "$DEPS_DIR/logs/port-sync.log" 2>&1 ||
  die "port sync failed; see $DEPS_DIR/logs/port-sync.log"

# Upstream (bce467bf, "Fix libidn2 using non-macOS 11 functions") makes
# libidn2 fail to configure against APIs newer than the deployment target when
# the prefix is not /opt/local. Reapplied after every sync, which resets it.
LIBIDN2="$PREFIX/var/macports/sources/rsync.macports.org/macports/release/tarballs/ports/mail/libidn2/Portfile"
OPT='configure.cflags-append -Werror=unguarded-availability-new'
[[ -f "$LIBIDN2" ]] || die "libidn2 Portfile not found at $LIBIDN2"
grep -qF -- "$OPT" "$LIBIDN2" || printf '\n%s\n' "$OPT" >> "$LIBIDN2"

if [[ "$MODE" == macports-only ]]; then
  echo "==> MacPorts ready; ports not installed (--macports-only)"
  exit 0
fi

# --- Ports ---------------------------------------------------------------------
for ref in $GIMP_REFS; do
  log="$DEPS_DIR/logs/ports-$ref.log"
  echo "==> Installing the ports for $ref (log: $log)"
  # shellcheck disable=SC2046 # the list is deliberately word-split into port names and variants
  env PATH="$PREFIX/bin:$CLEAN_PATH" "$PORT" -N install $(cat "$LISTS_DIR/$ref.txt") > "$log" 2>&1 ||
    die "port install for $ref failed; see $log"
done

if find "$PREFIX/lib" -maxdepth 1 -name 'libX11*.dylib' | grep -q .; then
  echo "!! X11 libraries are installed in $PREFIX/lib; a port in all-deps-uni.txt pulled in X11 (upstream warns about the same)." >&2
fi

echo "==> Summary"
echo "-- $(env PATH="$PREFIX/bin:$CLEAN_PATH" "$PORT" -q installed active | wc -l | tr -d ' ') active ports in $PREFIX"
echo "-- $(du -sh "$PREFIX" | cut -f1) on disk"
