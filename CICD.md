# CI/CD

Glims is a SwiftPM package with an AppKit app and no `.xcodeproj`. CI builds
and tests with `swift build` / `swift test`, then proves the packaging path by
running `scripts/build-app.sh --shell-only` into `dist/Glims.app` and launching the bundle
with `--smoke-test`. The release workflow uses the self-hosted engine Mac to build and verify
a complete editor on a tag and publishes
an unsigned, ad-hoc-signed `.zip` and `.dmg` as a GitHub Release.

The GIMP engine and the adapter are not built on GitHub's hosted runners: the
dependency prefix takes hours to build from source. They are checked locally
(`scripts/engine-matrix.sh`, or its steps `scripts/build-engine.sh`,
`scripts/build-adapter.sh --test` and `scripts/check-bundle.sh`) and nightly
on a self-hosted Mac (`engine-nightly.yml`, below). Normal app builds and release artifacts include the pinned engine; a hosted
CI shell build is explicitly for interface verification only.

## Workflows

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `.github/workflows/ci.yml` | Pull requests, pushes to `main`, manual dispatch | License and bundle-id assertions, script syntax, `swift build`, `swift test`, `.app` assembly with the notices check, a smoke launch, on a pinned Xcode toolchain. |
| `.github/workflows/zai-code-review.yml` | Pull requests (opened / reopened / synchronize / ready for review) | Automated review pass with GLM 5.3 (deep) and MiMo v2.6 Pro (fast tier), with StepFun step-5-preview as the last-resort fallback. |
| `.github/workflows/engine-nightly.yml` | Nightly (02:17 UTC), manual dispatch | On a self-hosted Mac: `scripts/engine-matrix.sh` builds the pinned engine and upstream master, runs the adapter conformance tests, the interface diff, builds the app with each engine bundled and checks the bundle with the build trees unreadable. Never runs on pull requests. |
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
./scripts/build-app.sh --shell-only
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
These notices cover Swift packages. The engine bundler generates a separate
`Engine-Notices.txt` covering the engine and bundled dependencies; release
archive checks require both files.

## PR review (`zai-code-review.yml`)

Identical to the workflow in the other repos in the family, including its
hardening:

- It is a `pull_request_target` workflow, which exposes repository secrets and a
  write-capable token, so it **only runs for branches in this repository**,
  never for a fork's.
- The third-party action is pinned to an immutable commit rather than a moving tag.
- One review per PR at a time; a superseded review of an outdated diff is cancelled.
- `ZAI_API_KEY` is required; `MIMO_API_KEY` and `STEPFUN_API_KEY` are optional.
  Empty secrets keep the dedicated fast tier and the outage fallback disabled.
- Because `pull_request_target` reads the workflow from the base branch, the PR
  that introduces this file is not itself reviewed; reviews start with the next.

Findings are advice, not a gate. `CLAUDE.md` describes how to triage them.

## Engine nightly (`engine-nightly.yml`)

The job runs on a self-hosted runner labelled `glims-engine`
(`.github/actionlint.yaml` declares the label). To set one up on an Apple
Silicon Mac:

1. Register a GitHub Actions runner for the repository with the labels
   `self-hosted`, `macOS`, `ARM64` and `glims-engine`, and run it as a
   dedicated user.
2. In the runner's checkout of the repository, run
   `scripts/bootstrap-deps.sh` once (hours) and then
   `scripts/build-engine.sh` for each set in `MATRIX_SETS`
   (`scripts/engine.env`). The checkout step keeps the ignored `_deps/` and
   `_engine/` trees (`clean: false`), so later runs rebuild only what
   upstream changed.
3. Install Xcode at the version `ci.yml` pins.

The workflow has no `pull_request` trigger on purpose: a self-hosted runner
must never run code from forks. The summary table goes to the run's summary
page, and the logs stay on the runner under `_engine/matrix/`.

The same run works locally: `scripts/engine-matrix.sh [GIMP_REF ...]`
(default: `MATRIX_SETS`). It writes `_engine/matrix/<time>/summary.md`, keeps
its test app outside the build trees, and exits non-zero when a build, test or
bundle check fails. An interface change reported by `interface-diff.py` alone
does not fail it; it is the cue to read the log.

## Releases (`release.yml`)

```sh
scripts/release.sh 0.2.0 --push   # bump Resources/Info.plist + README marker, commit, tag v0.2.0, push
```

The tag triggers `release.yml`. It refuses a tag that disagrees with the
committed `CFBundleShortVersionString` or the README version marker, gates
publication on `swift test`, builds the engine and adapter, assembles the complete app with
`scripts/build-app.sh`, runs `scripts/check-bundle.sh` with the build trees
unreadable, checks
that the binary is arm64-only, stamps `CFBundleVersion` with the run number,
and packages `Glims-v<X.Y.Z>-macos-arm64.zip` and `.dmg`. It checks the GPL text
and the notices inside both archives before publishing, and after publishing it
downloads what GitHub serves and byte-compares it with the build output,
removing a mismatched asset rather than serving it.

The app is arm64-only because the GIMP engine it will link is built for the
host architecture (`docs/plan.md`).

**Signing.** The app is ad-hoc signed (`codesign --sign -`), which Apple
Silicon requires to launch, and carries no Developer ID signature. The user
explicitly excluded notarization. Release qualification checks the signatures,
bundled dependencies, corresponding sources and license notices; it does not
require a notarization submission.
