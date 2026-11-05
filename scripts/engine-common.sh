# Shared by the engine scripts (bootstrap-deps.sh, build-engine.sh); source it,
# do not run it. Defines the engine paths, the pins from engine.env, and helpers.
# shellcheck shell=bash

ROOT="${ROOT:?set ROOT before sourcing engine-common.sh}"
# shellcheck source=engine.env
source "$ROOT/scripts/engine.env"

# The GIMP refs of all engine sets, in order.
GIMP_REFS=""
for engine_set in $ENGINE_SETS; do GIMP_REFS="$GIMP_REFS${GIMP_REFS:+ }${engine_set%%:*}"; done
unset engine_set

DEPS_DIR="$ROOT/_deps"
PREFIX="$DEPS_DIR/macports"
PORT="$PREFIX/bin/port"
ENGINE_DIR="$ROOT/_engine"
# MacPorts and the engine builds must not see Homebrew or other user tools.
CLEAN_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

die() { echo "!! $*" >&2; exit 1; }

# sanitize_environment: drop caller settings that would silently change what
# gets built or which repository git touches (compiler and linker flags, SDK
# and install redirections, Python and pkg-config overrides, DYLD_*, GIT_*).
sanitize_environment() {
  local name
  for name in CFLAGS CXXFLAGS OBJCFLAGS OBJCXXFLAGS CPPFLAGS LDFLAGS CPATH \
              C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH LIBRARY_PATH \
              SDKROOT DESTDIR PKG_CONFIG PKG_CONFIG_PATH PKG_CONFIG_LIBDIR \
              PKG_CONFIG_SYSROOT_DIR PYTHONPATH PYTHONHOME PYTHONSTARTUP \
              PYTHONUSERBASE GI_TYPELIB_PATH XDG_DATA_DIRS; do
    unset "$name"
  done
  while IFS= read -r name; do
    unset "$name"
  done < <(compgen -e | grep -E '^(DYLD_|GIT_)' || true)
  return 0
}

# acquire_lock: allow one engine script at a time; they share the mirrors,
# the prefix and the logs. A lock left by a process that no longer runs is
# taken over.
acquire_lock() {
  ENGINE_LOCK="$ENGINE_DIR/.lock"
  mkdir -p "$ENGINE_DIR"
  if ! mkdir "$ENGINE_LOCK" 2>/dev/null; then
    local holder
    holder="$(cat "$ENGINE_LOCK/pid" 2>/dev/null || true)"
    if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
      die "another engine script is running (pid $holder, lock $ENGINE_LOCK)."
    fi
    rm -rf "$ENGINE_LOCK"
    mkdir "$ENGINE_LOCK" || die "cannot take the lock $ENGINE_LOCK."
  fi
  echo "$$" > "$ENGINE_LOCK/pid"
  trap 'rm -rf "$ENGINE_LOCK"' EXIT
  return 0
}

# update_mirror NAME URL: create or refresh the bare blobless mirror
# $ENGINE_DIR/NAME.git. Sources are read from it or checked out of it as
# worktrees; nothing in a mirror is ever modified.
update_mirror() {
  local mirror="$ENGINE_DIR/$1.git" url="$2"
  if [[ ! -d "$mirror" ]]; then
    git clone --quiet --bare --filter=blob:none "$url" "$mirror"
  fi
  # A bare clone has no fetch refspec; without one, fetch would leave branches
  # such as master stale while tags update.
  git -C "$mirror" remote set-url origin "$url"
  git -C "$mirror" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
  git -C "$mirror" fetch --quiet --tags --prune origin
  return 0
}

# run_with_timeout SECONDS LOG COMMAND...: run COMMAND in its own process
# group with output to LOG; after SECONDS, stop the whole group (gimp-console
# and the plug-in processes it started) and return 124.
run_with_timeout() {
  local limit="$1" log="$2" pid waited=0 grace=0
  shift 2
  set -m
  "$@" < /dev/null > "$log" 2>&1 &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= limit )); then
      kill -TERM -- "-$pid" 2>/dev/null || true
      while kill -0 "$pid" 2>/dev/null && (( grace < 10 )); do sleep 1; grace=$((grace + 1)); done
      kill -KILL -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}
