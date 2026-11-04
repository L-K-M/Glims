#!/usr/bin/env bash
# Cuts a release: bumps the version, commits, tags "v<version>", and with --push
# pushes branch + tag — which triggers .github/workflows/release.yml to test,
# build, package (.zip + .dmg), and publish the GitHub Release. CI derives the
# released version from the tag and refuses a tag that disagrees with the
# committed CFBundleShortVersionString or the README version marker, both of
# which this keeps in step.
#
#   scripts/release.sh 0.2.0          # bump Resources/Info.plist + README, commit, tag v0.2.0
#   scripts/release.sh 0.2.0 --push   # …also push the commit + tag (CI then publishes)
#   scripts/release.sh                # tag the current version as-is
#   scripts/release.sh --check        # print the resolved config; change nothing
#
# Usage: scripts/release.sh [X.Y[.Z]] [--push]
# Shared engine: https://github.com/L-K-M/release-tool (this stub only sets config).
# The plist kind edits Resources/Info.plist via /usr/libexec/PlistBuddy — run on macOS.
set -euo pipefail

export RELEASE_APP_NAME="Glims"
export RELEASE_KIND="plist"
export RELEASE_PLIST="Resources/Info.plist"
export RELEASE_CI_NOTE="CI (release.yml) will now test, build, package (.zip + .dmg), and publish the GitHub Release for <tag>."
export RELEASE_INVOKED_AS="scripts/release.sh"

BIN="${LKM_RELEASE_BIN:-lkm-release}"
command -v "$BIN" >/dev/null 2>&1 || {
  echo "error: lkm-release not found — clone https://github.com/L-K-M/release-tool and run ./install.sh" >&2
  exit 1
}
exec "$BIN" "$@"
