# CI/CD

Glims is a SwiftPM package with an AppKit app and no `.xcodeproj`. CI builds
and tests with `swift build` / `swift test`, then proves the packaging path by
running `scripts/build-app.sh` into `dist/Glims.app` and launching the bundle
with `--smoke-test`. The release workflow does the same on a tag and publishes
an unsigned, ad-hoc-signed `.zip` and `.dmg` as a GitHub Release.

The GIMP engine and the adapter are not built in CI: the dependency prefix
takes hours to build from source. Their build and conformance tests run
locally (`scripts/build-engine.sh`, `scripts/build-adapter.sh --test`). Phase
1 in [`docs/plan.md`](docs/plan.md) plans a nightly engine matrix on a
self-hosted runner with a prebuilt prefix.

## Workflows

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `.github/workflows/ci.yml` | Pull requests, pushes to `main`, manual dispatch | License and bundle-id assertions, script syntax, `swift build`, `swift test`, `.app` assembly with the notices check, a smoke launch, on a pinned Xcode toolchain. |
| `.github/workflows/zai-code-review.yml` | Pull requests (opened / reopened / synchronize / ready for review) | Automated review pass with GLM 5.3 (deep) and StepFun step-5-preview (fast tier), with MiMo as the outage fallback. |
| `.github/workflows/release.yml` | Pushing a `v*` tag (e.g. `v0.2.0`) | Check the tag against the committed versions, re-run tests, build the `.app`, package `.zip` + `.dmg`, check the notices inside both archives, publish a GitHub Release, then byte-compare the published assets. |

## Continuous integration (`ci.yml`)

One job on `macos-26` selecting **Xcode 26.0** via `maxim-lobanov/setup-xcode`,
pinned so a runner-image bump can't silently change the toolchain. The app's
deployment target stays macOS 13 (`LSMinimumSystemVersion`); building on a
newer SDK does not raise it. In-progress runs for the same *PR branch* are
cancelled on a new push; main-branch runs are never cancelled.

Third-party actions are pinned to immutable commit SHAs for the same reason
`zai-code-review.yml` pins its action.

### Running CI checks locally

```sh
bash -n scripts/*.sh
swift build
swift test
./scripts/build-app.sh
dist/Glims.app/Contents/MacOS/Glims --smoke-test
```

## License notices

`Resources/Third-Party-Notices.txt` is generated from `Package.resolved` and
the package checkouts by `scripts/third-party-notices.sh` (which runs
`scripts/swiftpm-notices.py`, shared with RelayBar). Regenerate it after any
dependency change:

```sh
swift package resolve
scripts/third-party-notices.sh
```

`build-app.sh` runs the same script with `--check` and fails when the committed
file is stale. The app ships it with the GPL text (`LICENSE.txt`) in
`Contents/Resources`, and CI and the release workflow assert both are present.
The notices cover Swift packages only; the GIMP engine and its dependencies must
be added before any build bundles them.

## PR review (`zai-code-review.yml`)

Identical to the workflow in the other repos in the family, including its
hardening:

- It is a `pull_request_target` workflow, which exposes repository secrets and a
  write-capable token, so it **only runs for branches in this repository**,
  never for a fork's.
- The third-party action is pinned to an immutable commit rather than a moving tag.
- One review per PR at a time; a superseded review of an outdated diff is cancelled.
- `ZAI_API_KEY` is required; `MIMO_API_KEY` and `STEPFUN_API_KEY` are optional.
  Empty secrets keep the outage fallback and the dedicated fast tier disabled.
- Because `pull_request_target` reads the workflow from the base branch, the PR
  that introduces this file is not itself reviewed; reviews start with the next.

Findings are advice, not a gate. `CLAUDE.md` describes how to triage them.

## Releases (`release.yml`)

```sh
scripts/release.sh 0.2.0 --push   # bump Resources/Info.plist + README marker, commit, tag v0.2.0, push
```

The tag triggers `release.yml`. It refuses a tag that disagrees with the
committed `CFBundleShortVersionString` or the README version marker, gates
publication on `swift test`, builds the app with `scripts/build-app.sh`, checks
that the binary is arm64-only, stamps `CFBundleVersion` with the run number,
and packages `Glims-v<X.Y.Z>-macos-arm64.zip` and `.dmg`. It checks the GPL text
and the notices inside both archives before publishing, and after publishing it
downloads what GitHub serves and byte-compares it with the build output,
removing a mismatched asset rather than serving it.

The app is arm64-only because the GIMP engine it will link is built for the
host architecture (`docs/plan.md`).

**Why unsigned.** The app is ad-hoc signed (`codesign --sign -`), which Apple
Silicon requires to launch, but carries no Developer ID signature and is not
notarized, like the other apps in the family. A distributable build of the
finished app needs Developer ID signing and notarization of the app, GTK3,
Python and every plug-in executable; `docs/plan.md` lists that under work
before any public release.
