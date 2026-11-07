# AGENTS.md

Glims is a native macOS image editor: an AppKit and RigiUI interface over
GIMP's GUI-free engine. Read [`docs/plan.md`](docs/plan.md) for architecture,
the engine update model and the current phase. Read
[`docs/design.md`](docs/design.md) for interface rules. The research behind
both is in [`docs/research/`](docs/research/README.md).

## Status

Phase 0 (spike) is finished with a go verdict
([`docs/phase0-report.md`](docs/phase0-report.md)); phase 1's first
implementation is complete (`docs/plan.md`, "Phase 1"): plug-in commands
with their own dialogs work,
`scripts/build-app.sh --engine` makes a self-contained app, and the Tools and
Tool Options palettes drive GIMP's paint tools, selections, Transform, Text
and paths (a Path tool and a Paths palette). The engine dependency prefix is
built (`_deps/macports`);
the four engine sets in `scripts/engine.env` (GIMP 3.2.8, 3.2.0, master and
3.0.8) build unmodified into `_engine/install/<ref>`; adapter v1 (`Engine/`)
passes its 198 conformance checks against all four. The app loads the adapter
at run time and edits real images through it: tiled canvas, painting, a
Layers palette, Gaussian Blur, undo, save and export.
Keep `docs/plan.md` current as the work proceeds.

## Layout

| Path | Contents |
|---|---|
| `Sources/GlimsKit/` | The AppKit interface, built with RigiUI. Never includes GIMP headers. |
| `Sources/GlimsKit/RigiIncubator/` | Generic controls incubated here before they move to Rigi. |
| `Sources/Glims/` | The thin executable. |
| `Tests/GlimsKitTests/` | Unit tests. |
| `Resources/` | `Info.plist` (the release version source), the generated `Third-Party-Notices.txt` and app icon. |
| `media-sources/` | The app icon master and its generation prompt. |
| `scripts/` | Build, release, app assembly and license-notice scripts. |
| `Engine/` | The C adapter over GIMP's engine, and its conformance tests in `Engine/tests/`. |
| `Sources/CGlimsEngine/` | The facade header `glims_engine.h`, shared by the adapter and the app. |
| `docs/` | Plan, design and research records. |

## Build, test and release

- Toolchain: Xcode 26 or later. CI pins Xcode 26.0 on `macos-26`; the shell
  was last built locally with Xcode 27.2 (Swift 6.4.2). Swift tools 5.9 in
  Swift 5 language mode, macOS 13 deployment target (Rigi's minimum; GIMP
  itself needs macOS 11).
- `swift build` and `swift test`.
- `scripts/build-app.sh [--debug] [--engine GIMP_REF | --shell-only]` assembles
  `dist/Glims.app`: it checks the third-party notices, copies `LICENSE` in as
  `LICENSE.txt`, and signs ad-hoc or with `CODE_SIGN_IDENTITY`. Normal builds
  bundle the pinned engine; `--engine` selects another built engine set and its adapter with
  `scripts/bundle-engine.py` (libraries relinked to `@rpath`, typelibs
  recompiled, `Engine-Notices.txt` generated, every license checked
  against a reviewed list), so the app runs without `_engine/` or `_deps/`.
- `scripts/check-bundle.sh [APP]` runs the conformance tests and the app's
  `--engine-smoke-test` against a bundled engine with `_engine/` and
  `_deps/` unreadable (sandbox-exec). Run it after changing the bundler,
  the adapter's bundle paths, or the engine set.
- `scripts/engine-matrix.sh [GIMP_REF ...]` runs the whole chain (engine
  build, adapter tests, interface diff against the pinned engine, app with
  the engine bundled, bundle check) for each set in `MATRIX_SETS`
  (`scripts/engine.env`: the pinned engine and master) and prints a table.
  The nightly workflow runs it on a self-hosted Mac (`CICD.md`).
- `dist/Glims.app/Contents/MacOS/Glims --smoke-test` builds the workspace
  window, checks it and exits; `--version` prints the bundle version.
- `GLIMS_ENGINE_LIBRARY=<adapter dylib> dist/Glims.app/Contents/MacOS/Glims`
  runs the app on an engine; `--engine-smoke-test` drives a document through
  the interface code and measures main-thread stalls during plug-in calls.
  Engine-free interface development requires `build-app.sh --shell-only`;
  never distribute that bundle.
- `scripts/build.sh [--clean] [--debug] [--run] [--install] [--zip] [--dmg] [--check]`
  wraps `build-app.sh` through the shared `lkm-build` engine.
- `scripts/release.sh [X.Y.Z] [--push]` bumps `Resources/Info.plist` and the
  README version marker, commits and tags through the shared `lkm-release`
  engine. `--push` triggers `release.yml`.
- Both engines come from https://github.com/L-K-M/release-tool (clone, then
  `./install.sh`). `LKM_BUILD_BIN` and `LKM_RELEASE_BIN` point the stubs at a
  checkout instead.
- After any dependency change, run `scripts/third-party-notices.sh` and commit
  `Resources/Third-Party-Notices.txt`; `build-app.sh` fails while it is stale.
- Rigi is pinned by revision in `Package.swift`. Before moving the pin, run
  Rigi's own checks at the new revision; then regenerate the notices.
- `scripts/bootstrap-deps.sh [--check] [--macports-only]` builds the engine's
  dependency prefix in `_deps/macports` from the pins in `scripts/engine.env`.
  The first full run builds every port from source and takes hours; run it
  detached and read `_deps/logs/`. Never run two at once.
- `scripts/build-engine.sh [--check] [GIMP_REF]` builds babl, GEGL and GIMP
  for one engine set from `ENGINE_SETS` in `scripts/engine.env` (default: the
  pinned engine) into `_engine/install/<GIMP_REF>`, fails if any upstream
  source tree changed, and smoke-tests `gimp-console`. Engine tools must never
  write to the user's real `HOME`, `~/.cache` or GIMP settings: run them with
  the throwaway `HOME`, `XDG_CACHE_HOME` and `GIMP3_DIRECTORY` the script uses.
  Only one engine script runs at a time (`_engine/.lock`).
- The app icon is generated: `media-sources/icon.png` is the unedited master
  (made with ChatGPT's image tool, prompt in `media-sources/IconPrompt.txt`);
  `swift scripts/generate-icons.swift` writes `Resources/AppIcon.png` and
  `Resources/AppIcon.icns`. Commit all three together.
- `scripts/build-adapter.sh [--test|--perf|--check] [GIMP_REF]` builds
  `_engine/adapter/<GIMP_REF>/libglimsengine.dylib` with GIMP's own
  gimp-console flags and objects (read by `scripts/adapter-flags.py`), checks
  it exports only `glims_engine_get_api`, and with `--test` runs the
  conformance tests with a throwaway home. `--perf` times rendering, panning
  and painting on a GIMP-made 24 MP, 20-layer image (made once with
  `GIMP_3_2_0`). Any facade change that is not purely additive bumps
  `GLIMS_ENGINE_API_VERSION`.
- `python3 -I scripts/interface-diff.py _engine/adapter/<ref>/obj
  _engine/src/<old>/gimp _engine/src/<new>/gimp` lists the GIMP functions the
  compiled adapter calls whose prototypes differ between two engine trees,
  and members of GIMP structs the adapter names that disappeared. Run it
  before building against a new engine.
- `scripts/make-fixtures.sh [GIMP_REF]` regenerates the conformance fixtures
  in `Engine/tests/fixtures` with GIMP's own engine (default `GIMP_3_2_0`).
- [`CICD.md`](CICD.md) describes the workflows.

## Architecture boundaries

```
GIMP, GEGL, babl (upstream, unmodified, pinned tags)
        │  internal app/ engine libraries, linked in-process
Engine/            C adapter: the only code that includes GIMP app headers
        │  versioned facade C API with opaque handles
Sources/GlimsKit/  Swift: AppKit + RigiUI, never includes GIMP headers
```

- **Zero engine-source patches.** The GIMP checkout stays byte-identical
  (`git status --porcelain` is empty). Build and packaging workarounds live in
  this repo's `scripts/` and are recorded in `docs/plan.md`. Never run
  upstream's `build/macos` scripts in the checkout: they can `git apply`
  patches to it.
- **The adapter is the seam.** Only `Engine/` touches GIMP internals. It uses
  neither AppKit nor GTK, so a future non-Mac front-end could reuse it. Keep
  version differences inside the adapter behind `GIMP_*_VERSION` checks.
- **Own the types at the facade.** Never pass, store or serialize raw GIMP
  enum values, macro constants or struct layouts across the facade. Upstream
  inserts enum values mid-enum and changes macro values in micro releases.
- **Never load libgimp into the app process.** It defines the same GObject
  type and function names as the engine. Plug-ins run as their own processes.
- **GIMP's GTK code is reference only.** Never link `app/display`,
  `app/tools`, `app/widgets`, `app/dialogs`, `app/actions`, `app/gui`,
  `app/menus`, `app/propgui` or `libgimpwidgets`. When porting behavior from
  them, do it deliberately and cite the upstream commit.
- **Rigi.** Generic controls and palette machinery belong in Rigi, with its
  gallery, guidelines and tests updated in the Rigi repo. Editor-specific views
  stay here. Follow Rigi's interface guidelines except where `docs/design.md`
  records a deliberate deviation.

## Upstream, naming and licensing

- Never file issues or merge requests with GIMP from this project, and never
  ask GIMP developers to debug Glims. GIMP forbids AI-generated contributions.
- Never present Glims as GIMP. Keep "GIMP" out of the product name, bundle
  identifier, config directory and user-visible branding. Factual statements
  such as "built on the GIMP engine" are fine. The bundle identifier is
  `ch.lkmc.Glims`; scope sub-identifiers under it.
- License: GPL-3.0-or-later. `README.md`, `Resources/Info.plist`
  (`NSHumanReadableCopyright`) and `LICENSE` must agree; CI asserts it.
  Confirm a dependency's license is GPL-compatible and redistributable in the
  app bundle before adding it, and ship its notice in the app.

## Third-party sources

GIMP, GEGL, babl and their dependencies are third-party code. Fetch them into
ignored directories (`_engine/`, `_deps/`) and build them only through this
repo's scripts. Read upstream sources freely; do not run their scripts or
build tools outside those scripts. `scripts/build.sh --clean` never removes
those directories.

## Verification

In CI: `swift test`, the `--smoke-test` launch of the assembled app, the
notices check in `build-app.sh`, and the license and bundle assertions.

Locally, on every engine set (the engine is not built in CI):

- The conformance tests (`scripts/build-adapter.sh --test`): renders against
  GIMP's own composite, XCF round trips, strokes and filters with their undo
  accounting, and import and export through the file plug-ins.
- The interface diff (`scripts/interface-diff.py`) on every engine bump.
- The app's `--engine-smoke-test` with `GLIMS_ENGINE_LIBRARY` set, which also
  measures main-thread stalls during plug-in calls.

Not yet covered: recorded stroke replays against goldens, and a latency
comparison with GIMP's own interface.

State exactly what was and was not checked. A successful compile of the
adapter is not evidence that engine behavior is unchanged.

## Updating the engine

1. Bump the pinned GIMP tag (and GEGL/babl if required) in one change.
2. Build. Fix compile errors in `Engine/` only.
3. Run the interface diff and the conformance tests.
4. Triage upstream UI commits in the range as port, ignore or new feature,
   using GIMP's own UI edits in the same commits as the template.
5. Record the cost (lines, files, hours, what caught each break) in the update
   log in `docs/plan.md`.

<!-- shared-rules:start -->

## Working practices

- Follow explicit task instructions over the default workflow below.
- Writing the code is not finishing the task. A task is finished when
  its changes are merged to main through a PR that passed CI and review,
  or when the user explicitly accepts a different end state.
- Start every task on current code. Fetch first, then cut the task
  branch from origin/main — never from a stale local branch or an old
  checkout. To continue existing work, rebase or merge the latest
  origin/main into it before editing. Never overwrite existing work to
  update.
- Resolve ambiguity before making consequential changes. State low-risk
  assumptions; ask when scope, safety, or expected behavior is unclear.
- Keep changes focused. Do not modify unrelated code, formatting, or comments.
- Prefer surgical edits over whole-file rewrites when the result is equivalent.
- Stage only intended files. Inspect the diff before committing.

## Communication

- Be concise, factual, and direct. Preserve necessary context and uncertainty.
- Avoid praise, motivational filler, emojis, and em dashes in new prose.
- Address the reader directly in user-facing copy.
- Report what was verified and what remains unverified. Never imply that an
  unavailable check passed.

## Code design

- Prefer early returns and shallow nesting. Separate logical blocks with
  blank lines.
- Use descriptive constants or enums for meaningful or repeated values.
  Use existing standard definitions for protocol/specification constants.
  Keep obvious, one-off values inline.
- Use enums for behavioral modes that would otherwise require ambiguous
  boolean arguments.
- Default members to private. Widen visibility only for required consumers,
  and review the change as an API design decision.
- Follow the repository's declared dependency boundaries. UI and controllers
  must use application services rather than directly accessing databases,
  subprocesses, sockets, or other low-level mechanisms.
- Encapsulate low-level mechanics behind domain-oriented interfaces.
- Reuse genuinely shared logic. Avoid speculative abstractions and layers
  that only forward calls.
- Prefer pure functions for business rules and immutable data where practical.
  Isolate side effects; document non-obvious state ownership or synchronization.
- Explain non-obvious intent, constraints, and tradeoffs in comments.
  Do not narrate obvious code. Add examples or diagrams when they clarify it.

## Validation and errors

- Validate untrusted input at entry points. Where practical, represent valid
  states in types and enforce persistent invariants in database schemas.
- Represent absence and failure explicitly.
- Use assertions for internal programming invariants, not external-input
  validation or required runtime error handling.
- Prefer explicit, actionable errors over silent failure or undocumented
  fallback. Document intentional recovery behavior.
- Never report a skipped or failed operation as successful.

## Bug fixes

1. Identify the root cause and define an observable success criterion.
2. Add a regression test and observe the relevant failure before fixing it.
3. Implement the fix and observe the test passing.
4. Check surrounding behavior for regressions and architectural consistency.

If an automated regression test is impractical, document the reproduction
and verification procedure. State any inability to reproduce the failure.

## Verification

- Run relevant tests and lint after changes.
- Choose coverage by affected behavior and risk, not patch size.
- Use integration or end-to-end tests for critical workflows and boundaries;
  test isolated business rules at the lowest effective level.
- Run broader suites for cross-cutting or high-risk changes, and the full
  required release checks before releasing.
- Validate the requested command, options, platform, and configuration.
  Unrelated green CI is not proof that the reported problem is fixed.
- Recheck after the final edit. Distinguish local checks from CI results.

## Commit messages

- Use a capitalized, imperative subject without a final period.
- Target 50 characters; never exceed 72.
- Separate the subject and body with one blank line.
- Wrap body text at 72 characters.
- Explain what changed and why. Leave implementation mechanics to the code.

## Implementation and review

Unless explicitly instructed otherwise:

1. Work on a focused branch cut from the latest origin/main and open a PR
   against main before reporting the task as done.
2. Inspect CI results and completed review feedback for the latest commit.
   A successful reviewer job does not mean the review found no problems.
3. Address important findings or explain why they do not apply. Handle minor
   findings according to the stopping rules below.
4. Evaluate each fix in the surrounding project, add regression coverage,
   and rerun affected checks before pushing.
5. Repeat until a stopping criterion is met.
6. Merge without asking again once the stopping criterion is met, required
   checks pass on the latest commit, and no unresolved blockers or required
   human review requests remain.

### Reviewer context limits

The automated PR reviewer does not see the user's original prompt or
conversation. It may suggest changes that go against or beyond what the
user asked for. Do not implement such suggestions. Note each conflict and
report it to the user at the end of the thread.

### Automated review stopping rules

Judge findings by verified impact, not the reviewer's severity label.
Important findings concern correctness, security, data loss, broken builds,
or materially degraded behavior/performance.

Track completed review rounds and consecutive rounds without important
findings. Reruns of the same revision and integration failures do not count.

- No applicable actionable feedback: finish immediately.
- First minor-only round: optionally fix worthwhile, low-risk findings.
  Do not manufacture another push merely to obtain another review.
- Two consecutive rounds without important findings: stop responding to
  automated nitpicks, even if actionable minor suggestions remain.
  Defer worthwhile leftovers rather than continuing the cycle.
- A confirmed important finding resets the minor-only streak. Address it
  and verify the fix before continuing.

After ten completed rounds, enter stabilization:

- Stop optional cleanup, refactoring, and nitpick fixes.
- One completed review without confirmed important findings is sufficient
  to finish, even if minor suggestions remain.
- Continue only for confirmed important defects. If resolving them stalls,
  report the blockers rather than continuing indefinitely.

These limits end optional automated-feedback work. They do not waive
confirmed blockers, unresolved human review requests, or required checks.

### Reviewer integration failures

After two consecutive reviewer-integration failures, stop and report the
review gap. Do not treat failures as approval. An explicit user instruction
may waive review; report that waiver rather than claiming review passed.

## Ending a task

- A task ends with its changes merged to main — not with code written,
  and not with a PR merely opened. An open PR is work in progress:
  monitor CI on the latest commit, address review findings per the
  stopping rules, and merge once the criteria are met.
- Never finish with uncommitted changes or unpushed commits in the
  worktree. Commit, push, and open or update the PR first.
- If a step is impossible (missing push access, CI failure, reviewer
  outage), report the exact blocker instead. Never present unreviewed or
  unmerged work as finished.
- Before finishing, confirm: the requested behavior is implemented
  without unrelated changes; relevant checks pass on the latest code;
  important review findings are addressed or rejected with reasons;
  deferred suggestions, remaining risks, and validation gaps are
  disclosed.
- The final response states where the work stands: branch, PR, CI
  status, review rounds completed, and whether it is merged.

<!-- shared-rules:end -->
