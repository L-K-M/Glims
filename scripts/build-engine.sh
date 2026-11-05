#!/usr/bin/env bash
# Builds babl, GEGL and GIMP from unmodified upstream sources against the
# dependency prefix from scripts/bootstrap-deps.sh, for one GIMP ref listed in
# ENGINE_SETS in scripts/engine.env.
#
#   scripts/build-engine.sh [GIMP_REF]           # default: the pinned engine (first set)
#   scripts/build-engine.sh --check [GIMP_REF]   # print the resolved configuration; change nothing
#
# Sources are detached worktrees of the bare mirrors in _engine/*.git, at
# _engine/src/<GIMP_REF>/{babl,gegl,gimp}. Builds run out of tree in
# _engine/build/<GIMP_REF>/ and install into _engine/install/<GIMP_REF>/.
# Reruns are incremental while the source commits and build options stay the
# same; when either changes (a new pin, master moving), the build and install
# trees for that ref are wiped and rebuilt, so nothing stale survives.
# Logs go to _engine/logs/.
#
# It follows upstream's build/macos/1_build-deps-macports.sh (babl, GEGL) and
# 2_build-gimp-macports.sh (GIMP) for a non-default MacPorts prefix without
# running them. Every source worktree must be unmodified before the build and
# after it: the zero-patch rule (AGENTS.md) is checked, not assumed. A short
# smoke test runs the installed gimp-console with a throwaway home and GIMP
# directory, so the user's settings and caches are never touched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=engine-common.sh
source "$ROOT/scripts/engine-common.sh"

MODE=build
REF=""
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    -h|--help) awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    -*) die "unknown option '$arg' (see --help)" ;;
    *) [[ -z "$REF" ]] || die "only one GIMP ref at a time"; REF="$arg" ;;
  esac
done

[[ -n "$REF" ]] || REF="${ENGINE_SETS%% *}"
REF="${REF%%:*}"
BABL_REF="" GEGL_REF=""
for set in $ENGINE_SETS; do
  if [[ "${set%%:*}" == "$REF" ]]; then
    IFS=: read -r _ BABL_REF GEGL_REF <<< "$set"
  fi
done
[[ -n "$BABL_REF" && -n "$GEGL_REF" ]] || die "$REF is not listed in ENGINE_SETS in scripts/engine.env."

SRC="$ENGINE_DIR/src/$REF"
BUILD="$ENGINE_DIR/build/$REF"
INSTALL="$ENGINE_DIR/install/$REF"
LOGS="$ENGINE_DIR/logs"
STAMP_FILE="$INSTALL/.glims-engine-stamp"

if [[ "$MODE" == check ]]; then
  echo "build-engine --check"
  echo "  GIMP:     $REF"
  echo "  babl:     $BABL_REF"
  echo "  GEGL:     $GEGL_REF"
  echo "  sources:  $SRC"
  echo "  build:    $BUILD"
  echo "  install:  $INSTALL ($( [[ -f "$STAMP_FILE" ]] && echo built || echo 'not built'))"
  echo "  deps:     $PREFIX ($( [[ -x "$PREFIX/bin/meson" ]] && echo ready || echo 'missing; run scripts/bootstrap-deps.sh'))"
  exit 0
fi

[[ "$(uname -s)" == Darwin ]] || die "the engine builds on macOS only."
[[ -x "$PREFIX/bin/meson" && -x "$PREFIX/bin/ninja" ]] || die "no meson/ninja in $PREFIX; run scripts/bootstrap-deps.sh first."
sanitize_environment
acquire_lock
mkdir -p "$SRC" "$LOGS"

# The environment upstream sets in .gitlab-ci.yml (.macos_environ), with PATH
# limited to the engine, the prefix and the system. Python must not drop
# __pycache__ directories into the source trees the zero-patch gate checks,
# and build tools (g-ir-scanner, babl, GEGL) cache under _engine/, not in the
# user's ~/.cache.
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export PATH="$INSTALL/bin:$PREFIX/bin:$CLEAN_PATH"
export PKG_CONFIG_PATH="$INSTALL/lib/pkgconfig:$PREFIX/lib/pkgconfig"
export XDG_DATA_DIRS="$INSTALL/share:$PREFIX/share"
export GI_TYPELIB_PATH="$INSTALL/lib/girepository-1.0:$PREFIX/lib/girepository-1.0"
export PYTHONDONTWRITEBYTECODE=1
export XDG_CACHE_HOME="$ENGINE_DIR/cache"
MESON_ARGS=(-Dprefix="$INSTALL" -Dbuildtype=debugoptimized
            -Dc_args="-I$PREFIX/include" -Dcpp_args="-I$PREFIX/include"
            -Dc_link_args="-L$PREFIX/lib" -Dcpp_link_args="-L$PREFIX/lib")
GIMP_OPTIONS=(-Drelocatable-bundle=no -Denable-default-bin=enabled -Dbuild-id="$GIMP_BUILD_ID")

# assert_pristine NAME: the zero-patch gate. Ignored files count too: a fresh
# worktree has none, and builds run out of tree.
assert_pristine() {
  local changes
  changes="$(git -C "$SRC/$1" status --porcelain --ignored --ignore-submodules=none)" ||
    die "cannot read the state of $SRC/$1; inspect it or remove it and rerun."
  [[ -z "$changes" ]] || die "$1 sources differ from upstream (zero-patch rule):
$changes"
  return 0
}

# checkout NAME REF: put a pristine detached worktree of the NAME mirror at REF.
checkout() {
  local name="$1" ref="$2" mirror="$ENGINE_DIR/$1.git" worktree="$SRC/$1" commit
  commit="$(git -C "$mirror" rev-parse --verify --quiet "$ref^{commit}")" || die "$name has no ref $ref."
  if [[ -e "$worktree/.git" ]]; then
    # git checkout carries local changes along, so refuse a dirty tree first.
    assert_pristine "$name"
    git -C "$worktree" checkout --quiet --detach "$commit" ||
      die "cannot check out $ref in $worktree; inspect it with 'git -C $worktree status' or remove it and rerun."
  else
    git -C "$mirror" worktree prune
    git -C "$mirror" worktree add --quiet --detach "$worktree" "$commit" ||
      die "cannot create the $name worktree at $worktree."
  fi
  echo "-- $name $ref ($(git -C "$worktree" rev-parse --short HEAD))"
  return 0
}

# wipe PATH: remove a generated tree, refusing anything outside _engine/.
wipe() {
  case "$1" in
    "$ENGINE_DIR"/build/*|"$ENGINE_DIR"/install/*) rm -rf "$1" ;;
    *) die "refusing to remove $1" ;;
  esac
  return 0
}

# build NAME [MESON_OPTION...]: configure when needed, then build and install.
build() {
  local name="$1" log="$LOGS/$REF-$1.log"
  shift
  echo "==> Building $name (log: $log)"
  : > "$log"
  if [[ ! -f "$BUILD/$name/build.ninja" ]]; then
    # A failed earlier setup leaves a directory meson will not reuse.
    wipe "$BUILD/$name"
    meson setup "$BUILD/$name" "$SRC/$name" "${MESON_ARGS[@]}" "$@" >> "$log" 2>&1 || die "$name: meson setup failed; see $log"
  fi
  ninja -C "$BUILD/$name" >> "$log" 2>&1 || die "$name: build failed; see $log"
  ninja -C "$BUILD/$name" install >> "$log" 2>&1 || die "$name: install failed; see $log"
  return 0
}

echo "==> Updating mirrors"
update_mirror babl "$BABL_REPO"
update_mirror gegl "$GEGL_REPO"
update_mirror gimp "$GIMP_REPO"

echo "==> Checking out sources"
checkout babl "$BABL_REF"
checkout gegl "$GEGL_REF"
checkout gimp "$REF"
git -C "$SRC/gimp" submodule sync --quiet --recursive
git -C "$SRC/gimp" submodule update --quiet --init --recursive
for name in babl gegl gimp; do assert_pristine "$name"; done

# Everything that decides what lands in the install tree. A mismatch means
# the existing build and install trees describe something else.
STAMP="$(printf '%s\n' \
  "babl $(git -C "$SRC/babl" rev-parse HEAD)" \
  "gegl $(git -C "$SRC/gegl" rev-parse HEAD)" \
  "gimp $(git -C "$SRC/gimp" rev-parse HEAD)" \
  "gimp-data $(git -C "$SRC/gimp/gimp-data" rev-parse HEAD)" \
  "prefix $PREFIX" \
  "deployment-target $DEPLOYMENT_TARGET" \
  "meson ${MESON_ARGS[*]}" \
  "gimp-options ${GIMP_OPTIONS[*]}")"
if [[ -f "$STAMP_FILE" && "$(cat "$STAMP_FILE")" == "$STAMP" ]]; then
  echo ".. sources and options unchanged; building incrementally"
else
  echo "-- sources or options differ from the last build; building $REF from scratch"
  wipe "$BUILD"
  wipe "$INSTALL"
fi
mkdir -p "$BUILD" "$INSTALL"
printf '%s\n' "$STAMP" > "$STAMP_FILE"

build babl
build gegl
build gimp "${GIMP_OPTIONS[@]}"

# Packaging workaround for GIMP 3.2.0 to 3.2.4 (fixed upstream in 3.2.6):
# repair typelib library paths in the install tree; a no-op otherwise.
echo "==> Checking the installed typelibs"
repairs="$(python3 -I "$ROOT/scripts/fix-typelibs.py" "$INSTALL" "$PREFIX")" ||
  die "repairing the typelibs failed"
if [[ -n "$repairs" ]]; then
  while IFS= read -r line; do echo "-- packaging workaround: $line"; done <<< "$repairs"
else
  echo ".. all typelibs resolve"
fi

echo "==> Checking that the sources are unmodified"
for name in babl gegl gimp; do assert_pristine "$name"; done
echo "-- babl, gegl and gimp (with gimp-data) are byte-identical to upstream"

echo "==> Smoke test"
CONSOLE="$INSTALL/bin/gimp-console"
[[ -x "$CONSOLE" ]] || die "$CONSOLE was not installed."
SMOKE_HOME="$ENGINE_DIR/smoke-home/$REF"
rm -rf "$SMOKE_HOME"
mkdir -p "$SMOKE_HOME"
"$CONSOLE" --version
# The first start queries every plug-in, which takes a while; a hang must
# still fail instead of blocking forever. GIMP 3 needs an explicit batch
# interpreter when several are installed. HOME and the XDG directories point
# into the throwaway home so caches (babl, fontconfig) stay out of the user's.
status=0
run_with_timeout 600 "$LOGS/$REF-smoke.log" \
  env HOME="$SMOKE_HOME" XDG_CACHE_HOME="$SMOKE_HOME/.cache" XDG_CONFIG_HOME="$SMOKE_HOME/.config" \
      GIMP3_DIRECTORY="$SMOKE_HOME/gimp" \
      "$CONSOLE" -i --batch-interpreter=plug-in-script-fu-eval -b '(gimp-quit 0)' || status=$?
(( status != 124 )) || die "gimp-console did not quit within 10 minutes; see $LOGS/$REF-smoke.log"
(( status == 0 )) || die "gimp-console exited with status $status; see $LOGS/$REF-smoke.log"
# A clean exit is not enough: plug-ins that fail to load still let
# gimp-console quit with status 0. Every installed plug-in must register,
# except those that by design register only when an outside program is
# installed (darktable, RawTherapee, a mail client).
CONDITIONAL_PLUG_INS=" file-darktable file-rawtherapee file-another-rawtherapee mail "
missing="" skipped=""
for plug_in in "$INSTALL"/lib/gimp/3.0/plug-ins/*/; do
  name="$(basename "$plug_in")"
  grep -q "plug-ins/$name/" "$SMOKE_HOME/gimp/pluginrc" && continue
  if [[ "$CONDITIONAL_PLUG_INS" == *" $name "* ]]; then
    skipped="$skipped $name"
  else
    missing="$missing $name"
  fi
done
[[ -z "$missing" ]] || die "plug-ins failed to register:$missing; see $LOGS/$REF-smoke.log"
[[ -z "$skipped" ]] || echo ".. optional plug-ins without their outside program:$skipped"
! grep -qE "Traceback|Failed to load shared library" "$LOGS/$REF-smoke.log" ||
  die "plug-ins reported load errors; see $LOGS/$REF-smoke.log"
criticals="$(grep -c "CRITICAL" "$LOGS/$REF-smoke.log" || true)"
(( criticals == 0 )) || echo "!! $criticals GLib CRITICAL message(s) during the smoke test; see $LOGS/$REF-smoke.log"
echo "-- gimp-console started, registered every plug-in it can and quit (log: $LOGS/$REF-smoke.log)"

echo "==> Summary"
echo "-- $(du -sh "$INSTALL" | cut -f1) installed in $INSTALL"
