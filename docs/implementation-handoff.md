# Glims implementation handoff — 2026-11-15

The user requested a native image editor that starts in five seconds, is fast,
usable and attractive, and has at least Photoshop 4 functionality. They then
asked to record the state and stop. **Do not claim that the goal is complete.**
Notarization is explicitly excluded. The signed bundles mentioned below are
test artifacts, not an assertion that `/Applications/Glims.app` was updated
to these heads or that public distribution has been qualified.

The last fetched GitHub main is `4a56b5ef646115ef414f0120f1414da60b9bbb89`.
The original `Glims` checkout is stale and has a pre-existing modified
`.gitignore`; preserve it. This handoff lives in the separate local branch
`docs/glims-implementation-handoff` and has not been pushed. The persistent
local journal and logs are in `../.glims-work-notes/continuation.md` relative
to the workspace's Glims worktrees. Read the latest entries: older entries are
chronological and may be superseded. Existing worktrees and unmerged branches
contain substantial unfinished work; do not remove them indiscriminately.

## Scope and remaining product work

Merged main has a native AppKit editor and a packaged engine, including common
painting, selections, layers and masks, filters, history, save/export, color
management and portions of Lab, CMYK, Bitmap, Duotone and Recorder. The
ledger in `completion.md` and later entries in `plan.md` describe the scope
and evidence; old dated entries describe their own candidates and should not
be read as current release claims. Physical Lab and ink adjustments, broader
layered Lab/CMYK editing and interchange, Bitmap/Duotone functionality,
Recorder/PSD preservation and physical-tablet and spoken-accessibility
qualification remain incomplete. Physical calibrated-display verification,
Full Keyboard Access and corresponding-source/license/signature/update
qualification remain open. The user says **no notarization**.

Normal local launches previously measured about 2.37–4.45 seconds with warm
OS caches. Unsupported/missing/invalid registry-seed fallback took about
10.46 seconds engine-only. These are not universal launch guarantees. Startup
PR #295 has already had two consecutive reviewer-integration failures and its
existing third attempt timed out. Under this repository's `AGENTS.md` stopping
rule, do not retry, bypass, redelegate, push or merge #295 or its dependent
startup branches without an applicable completed review or an explicit user
waiver. Other work may proceed independently. Do not present timeouts as
approval.

## Open reviewed candidates

At the stop request, three hosted Z.ai reviews were in progress. Keep at most
three concurrent hosted review jobs; do not open/update another PR that starts
a fourth until one completes. Inspect full review bodies and inline comments,
exact heads, CI and actual merge trees before merging. Never cancel main CI.

* [#354](https://github.com/L-K-M/Glims/pull/354), Duotone alternate-color
  PSD export, head `76fd9196ed13526f3a0b436299964f41e6d4bf3e`, in
  `Glims-wt-duotone-alternate-export`: native matrices and real-window export
  pass on four engines, Swift 1,806/0. A signed standalone bundle passed 2,268
  native, 17 preservation, 24 export, 13 composite and 3,371 editor checks
  with development trees denied. CI passed; hosted review is pending. One
  LongCat review attempt timed out without a verdict; do not redelegate that
  assignment or treat it as review. Source fixtures stayed unchanged.
* [#367](https://github.com/L-K-M/Glims/pull/367), Info palette, head
  `3e1bd99769ae7a67922f333b90a8f25dc306a800`, in
  `Glims-wt-info-palette`: asynchronous committed-composite sRGB/alpha and
  pointer coordinates, including a red/green fix for stale coordinates after
  scrolling. Four-engine window checks, Swift 1,808/0 and earlier signed
  bundle qualification passed. CI passed; exact-head hosted review pending.
  Native CMYK/Lab readouts and temporary preview sampling are not implemented.
* [#368](https://github.com/L-K-M/Glims/pull/368), flattened RGB copy of a
  layered Lab composite, head `706515e9184e8e17d6688b140df8262eab838b7d`, in
  `Glims-wt-layered-lab-rgb-copy`: four native matrices and LCMS/color/alpha
  checks, four real-window cases, Swift 1,808/0, and a signed bundle (2,268
  native / 3,371 editor checks) passed. CI passed; exact-head review pending.
  Earlier review findings on sanitizer behavior were addressed in merged
  #369; its process-group allegation does not describe the compiler child,
  which is launched in a new session. Review the new head independently.

## Local dependent work

* [#355](https://github.com/L-K-M/Glims/pull/355), composite-open error
  handling, local `eb8f50a24ed0cd6b448b92ce33b9ae45a76bf5bf` in
  `Glims-wt-composite-open-errors`, depends on #354. Its integration retains
  both the missing-file and new PSB fixtures; Swift 1,806/0 and four-engine
  native and real-window missing-file/Revert/retry checks passed. The source
  PSD SHA-256 remained `4169c367a7e4698f55955901849c38b8bd284dd61f8ddcbef8bafa70e54bb19b`.
  A signed bundle built. Its isolated native tests passed 2,268 conformance,
  17 preservation, 24 export and 16 composite checks; the full editor smoke
  was **interrupted by the user's stop request**, so the bundle check is not
  complete. Rerun it if continuing. Its LongCat review timed out without a
  verdict; do not redelegate that assignment. Do not publish until #354 is
  merged and a review slot is free.
* Sponge Recorder, local `18b2b51916f08b55e7b35cea5245aec6833c0a74` in
  `Glims-wt-recorder-sponge-final`, depends on #368. Swift 1,811/0, all four
  native matrices, 27 normal and 35 opaque Sponge capture checks per engine,
  and normal/opaque real-window recording, file round-trip, Undo and replay
  passed. Older-adapter refusal/Undo checks also passed. A signed isolated
  bundle passed 2,268 native and 3,371 editor checks; the focused bundled
  Sponge cases passed. The first attempted new-adapter window run omitted
  `GLIMS_EXPECT_SPONGE_CAPTURE=1` and incorrectly expected old-adapter
  behavior; the correctly configured reruns passed. Wait for #368 and hosted
  review before promotion. Further tablet/opaque-brush/eraser/mask Recorder
  branches are stacked on earlier work; preserve their order.
* Tablet capture, local `5a855bb364db645e5c23ab918be718c58c8e0a2f` in
  `Glims-wt-recorder-tablet-capture`, is staged on Sponge and is not yet
  user-facing replay completion. Swift 1,811/0 passed. Native matrices and
  34 focused capture checks passed on 3.2.8, 3.0.8 and 3.2.0; master was
  interrupted during conformance by the stop request. The separate V2
  coordinate fixture passed 152 checks on 3.2.8 and 3.0.8; run it on 3.2.0
  and master, and complete the master native matrix. A first test invocation
  passed a directory instead of its binary and refused safely; the corrected
  runs passed. Physical-tablet qualification is not established.
* Recorder Remove Step help, local `5c219a93db38098e462ddf2af406b6fe1182719f`
  in `Glims-wt-recorder-remove-help`: red/green native-window tests cover no
  image, no selection, replay and enabled selection; 59 checks pass on each
  engine, Swift 1,806/0. The earlier signed bundle belongs to `40f38d03`, not
  this newer head; rebuild and qualify the final head. A LongCat review timed
  out without a verdict; do not redelegate the same assignment. Wait for an
  available hosted-review slot.

3.0.8 runs sometimes reported `gimp_wire_read(): unexpected EOF` during
shutdown; master reported GIMP cache-XML cleanup warnings. Passing checks do
not resolve or erase these diagnostics.

## Working rules and continuation prompt

Follow the user's current `AGENTS.md` and repository rules. Prefer LongCat 2.5
through Pi for bounded helpers; use permitted free/Mistral/Devin fallbacks
when appropriate. Astra and Fable are forbidden for helpers; OpenAI/Anthropic
helpers need the rare stated exception. Do not retry/redelegate the specific
timed-out assignments above. Never use Finder windows or `open -R`; quit owned
GUI apps, resolve own dialogs, and release the `desktop` lease after each
bounded UI run. The last test was stopped; its app exited and the lease was
released. Honor other agents' desktop arbitration.

`Glims/_engine` and `Glims/_deps` are shared, often via ignored worktree
symlinks. Do not delete or rebuild them in place. `build-adapter.sh` uses a
single shared engine lock; serialize adapter builds and use unique absolute
`GLIMS_ADAPTER_ROOT` directories. Never rebuild producer objects/dylibs while
their tests consume them. Check worktree status, ignored files, active
processes, current GitHub heads and this journal before cleanup. Remove only
worktrees/branches created for completed work, with the non-force rules in
the user's `AGENTS.md`.

Suggested prompt for the next model:

> Continue Glims toward the user's five-second startup and Photoshop 4-level
> usability requirements, without notarization. First read this handoff,
> `docs/plan.md`, `docs/completion.md`, repository/user `AGENTS.md`, and the
> persistent `.glims-work-notes/continuation.md`. Check actual Git and CI
> state, restart only interrupted tests that are still needed, and preserve
> the original checkout and all unfinished worktrees. Honor the #295 review
> stopping rule, the three-review concurrency limit and the user's helper
> model and desktop-hygiene instructions. Continue the independent work and
> merge only tested exact heads with completed applicable reviews. Do not
> claim parity, a universal five-second launch or final release qualification
> without evidence.
