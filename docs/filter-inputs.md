# Snapshot filter inputs

Bump Map, Variable Blur, Selective Gaussian Blur and Negative Darkroom have
same-image height-map, blur-mask, contrast-reference and dodge/burn map choosers. The source is captured when Preview
starts; Apply to Pixels merges into the captured target and Undo restores its
pixels.
Other auxiliary-input operations and custom-config editors remain separate work.

API version 1 appends slot 147, `filter_begin_with_source`. It accepts explicit
positive target/source IDs for `gegl:bump-map`, `gegl:variable-blur`, and
`gegl:gaussian-blur-selective`. Targets are ordinary or previously rasterized
pixel-behaving layers. Editable sources and groups
are readable height maps, but are not destructive targets. Attached masks and
channels can also supply source pixels. Indexed images refuse because their
shared mutable Babl palette would not be frozen by a tile snapshot.

The engine flushes the source, obtains an owned with-effects buffer, duplicates
its native format/extent through GIMP's buffer-copy helper, and releases the
live intermediate before creating the target preview. GEGL copy-on-write
separates later source edits. A session-owned standalone buffer-source node
keeps the detached pixels alive; its aux edge is connected before the native
filter constructor/first Apply. Self and ancestor-group inputs therefore do not
retain a live dependency on the target preview. Logical snapshot data uses the
shared 512 MiB pixel-buffer limit. Item offsets add no translation beyond the
source buffer's native extent, matching the native source widget.

Auxiliary connections are not serialized by XCF. This path uses native
`to-be-merged` precision handling and places the preview below existing target
effects, then commits through the native pixel-merge Undo path. Both Begin and
Commit require enabled/unfrozen Undo with no open native Undo group. A refused
Commit keeps the preview cancellable; it never enables Undo itself. Native
history retention still controls how long the resulting step is retained.

Source selection keeps explicit IDs when names duplicate or rows disappear.
Preparation reads and native preview startup are counted through their main
thread callbacks; captured target/source IDs and request generations prevent
late replies from starting a replacement chooser's work. Cancel before Preview
does not write pixels. A closed window aborts a late successful session through
the existing preview lifecycle. Metadata queries and snapshots run off main.

The private/public harness passes 228 checks on each supported engine:
constant/ramp and alpha oracles, source effects and detached-copy independence,
source removal/Undo purge, self/group inputs, existing target-effect ordering,
Abort, pixel merge/Undo/Redo, native RGB/gray float snapshots, typed refusals,
public marshalling and Begin/Commit history guards. The real chooser/editor case
passes 20 checks per engine, including duplicate labels, missing sources, stale
completion isolation, Cancel, captured-document Preview and pixel Apply/Undo/Redo.
It also reproduces idle Escape reaching an unimplemented superclass action;
the window controller now treats that idle cancellation as a no-op. Additional
native cases cover attached masks, saved channels and editable text as sources,
a retained rasterized text target, source-offset policy, guarded sparse
over-budget refusal, and exact merged target/projection bytes after XCF reopen.
The 512 MiB refusal fixture prevents tile materialization rather than allocating
a dense image. The self-contained bundle passes 1,917 native and 2,370 app checks
with development outputs unreadable; 871 unit tests pass. No upstream source
is modified.

## Selective Gaussian contrast reference (candidate)

`gegl:gaussian-blur-selective` has one optional aux input, used as the contrast
reference for channelwise maximum-delta comparisons. The existing no-source
operation uses the target as that reference. The captured-source route instead
uses a detached snapshot through the same native-format, 512 MiB, merge-only
contract above. It adds no live source dependency or persistent auxiliary effect.
Multi-role and other compositor operations remain unsupported by slot 147.

The private native baseline executed 33 checks with only snapshot admission
failing. The actual-menu baseline executed three checks with only chooser
admission failing. The native allowlist and Swift source-role descriptor were
added after those observed failures. All four supported engines now pass 128
focused native checks and 28 actual-menu/form checks. General conformance
passes 1,917 checks on 3.2/master and 1,703 on 3.0.8.

The native oracles independently construct authentic GEGL graphs and cover
partial alpha, offsets, Cancel, Apply, one Undo, exact Undo/Redo, source
mutation/removal and representative refusal cases. The UI checks exercise
explicit contrast-reference choice, both installed numeric controls, captured
document ownership, stale chooser isolation, parameter reevaluation and the
same pixel/Undo lifecycle. CI on Xcode 26 reproduced a Swift 6.2 type-checker
limit in the fixture's combined array expression; explicitly typed byte
intermediates preserve the fixture while its CI rerun remains pending.
Other auxiliary roles, including multiple-role Displace and Oilify inputs,
remain outside this source contract.

## Negative Darkroom dodge/burn map (candidate)

The existing single-aux snapshot path now admits exactly `gegl:negative-darkroom`.
Its native output makes filtered pixels opaque; the chooser explicitly explains
that behavior and Undo restores the original alpha. All-four focused native
194 and actual chooser/form39 checks, plus 1,015 private leased units pass.
See `negative-darkroom-source.md` for source/reference boundaries and review,
AX, foreground-focus and final release gaps. Multi-role operations stay separate.
