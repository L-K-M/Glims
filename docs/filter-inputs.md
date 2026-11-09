# Snapshot filter inputs

Bump Map now has a same-image height-map chooser. The source is captured when
Preview starts; Apply to Pixels merges into the captured target and Undo
restores its pixels. Other auxiliary-input operations and custom-config editors
remain separate work.

API version 1 appends slot 147, `filter_begin_with_source`. It accepts explicit
positive target/source IDs, currently for `gegl:bump-map`. Targets are ordinary
or previously rasterized pixel-behaving layers. Editable sources and groups
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
