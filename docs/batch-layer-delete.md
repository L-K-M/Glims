# Captured layer deletion

The batch Delete path captures 1–256 distinct positive layer IDs and validates
the complete vector on the engine thread before changing selection or history.
Each source must be an attached ordinary pixel-layer object in the requested
image. Groups, structured subclasses and layer masks with live effects refuse.
Ordinary layer masks, layer effects and native layer locks remain supported.

Readiness, floating-selection resolution, enabled/unfrozen Undo and an idle
native Undo group are checked first. Deletion follows native lock policy:
locking pixels, position or transparency does not prevent removing the layer.
Distinct ordinary leaves cannot contain one another, so removing one cannot
detach another admitted source. Native removal is a void operation with those
entry preconditions; ordinary reported failures precede the first removal.

One native structural Undo group contains all removals. A weak selection
companion is pushed first, while every recorded object is attached. Undo pops
it last after native layer restoration; Redo pops it first before removal.
Surviving selected layers retain their order. If none survive, the first
remaining tree row is selected; an empty image has no layer selection.
Native item Undo owns removed data; the selection companion retains weak
identities only. Native history limits can expire the operation normally.

API version 1 appends slot 146, `image_delete_layers`. The document captures
its selection before queueing, refuses a pending replacement target, and keeps
refresh/completion counted through global exclusive work and image close.
The Layer menu and Layers palette menu/button expose the captured batch while
preserving the existing single-layer Delete route.

The dedicated live case `GLIMS_SMOKE_CASE=batch-delete` passes 19 checks on
each supported engine: actual menu/palette actions, exact native IDs and
ordered selection, one-step Undo/Redo, independent image pixels, refusal of a
queued New Layer target, later native selection changes, a queued stale-target
failure without partial deletion, and exactly-once completion before image
destruction. Existing multiselection and batch-duplicate cases pass on all four
engines; all 871 unit tests pass.

The private/public harness passes 717 checks on every supported engine,
including mixed nested parents, ordinary masks and committed effects, locked
sources, quiet preflight refusals, real stroke/filter/floating sessions,
256-source deletion, repeated exact Undo/Redo and Undo-purge finalization.
Native topology/raw-pixel/property snapshots are supplemented by independently
known source colors, expected remaining IDs/count/order and a metadata sentinel.
They do not certify every GEGL parameter, all metadata families or every
structured subclass separately.

The cold nested-group regression exposed a visible thumbnail bug: GEGL's 1×1
shortcut could return an old red/blue pixel after a second Redo. Thumbnails now
explicitly validate that region through the same native tile-handler API the
image renderer uses. Four cold public-thumbnail assertions run before the
test's ordinary tiled reads and pass on every engine. The test's own raw
1×1 snapshot reads use a two-pixel tiled read and hash the same logical pixel,
avoiding that shortcut without discarding any pixel assertion. No upstream
source was changed. Final isolated-bundle verification is pending.
