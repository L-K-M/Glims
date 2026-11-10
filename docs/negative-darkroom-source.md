# Captured Negative Darkroom source

Negative Darkroom now offers a same-image dodge/burn map through the existing
snapshot source chooser. Preview captures detached source pixels and committed
effects. Later source changes, deletion or another front document cannot
retarget that preview. Apply to Pixels merges into the captured target as one
native Undo; it does not save an auxiliary effect or add a live dependency.

The operation's native format makes filtered pixels opaque. The chooser says
so before Preview. Undo restores the original partial alpha. This is measured
native behavior, not a promise to preserve alpha or a replacement filter graph.
The four-operation allowlist remains exact; multi-role Displace and Oilify
are separate work. No native facade slot or upstream source is changed.

## Recorded verification (2026-11-10)

The old immutable API165 producer ran 78 focused native checks and failed
exactly the named source admission. The independent opaque/partial-alpha,
source-effect and offset reference cases already passed. New production at
`a668bec` passes 194 native checks on each of 3.2.8, 3.2.0, 3.0.8 and master.
General conformance passes 1,917/1,917/1,703/1,917. Native pixel expectations
come from independently configured GEGL/Core paths, including actual raw
alpha 36 becoming 255. Compile-only driver manifests freeze its producer
objects and sources; the driver never executes the harness itself.

Swift warning copy at `764c7b8` has three passing pure tests. Dedicated fixture
`90f58d8` passes all 39 actual chooser/form checks on all four engines and
1,015 units in a proper private leased run. It checks visible warning, source
Cancel, target-retarget refusal, stale chooser replacement, a separate native
reference versus target-as-source, both numeric controls, detached reevaluation,
parameter Cancel, opaque Apply/one Undo/no auxiliary effect, exact alpha Undo,
Redo, B ownership, busy, deleted-source refusal and close/late Preview cleanup.

Each owned app exited0 and released the desktop. The 3.2.0 immediate external
AX read and its full-unit after-read were incomplete; the other three engine
snapshots and the later Tool Options full-unit snapshot reported no dialog.
Those later reads do not attest the earlier instants. B ownership is established by the captured controller/native state;
this fixture does not claim real B foreground focus. Temporary signed shells
load immutable external producers; they are not release bundles.

One Glyph coding attempt supplied the initial bounded drafts. The authors
corrected invalid APIs and weakened/vacuous oracles before execution; its draft
report is not independent approval. Root independently inspected the narrow
production delta: one exact native allowlist entry, the matching Swift role
and explicit alpha explanation; the shared snapshot/preview pipeline is
unchanged. Completed hosted review, latest CI/merge and final combined release
remain gates. Evidence is indexed in
`/tmp/glims-completion/negative-darkroom-ui90-all-four-verification.json` and
`negative-darkroom165-positive-<engine>-first.log`.
