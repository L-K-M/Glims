# Channel commands in the main menus

Image > Channels now mirrors Channel Attributes, Duplicate, Delete and Return
to Layers. Select > From Channel offers Replace, Add, Subtract and Intersect.
Main actions require exactly one cached selected saved channel. They never
silently use the first of multiple selections, Quick Mask, a removed row or a
remembered drawable. Return to Layers accepts several selected channels and
needs a layer to return to. Existing context actions retain their clicked ID.

Validation and action share cached readiness: live document, no attached sheet,
preview, global busy activity or structural target command, and no pending
counted work. Pending channel picks are mirrored before settlement, so that
last gate prevents editing the wrong native selection. Malformed operation
tags, including negative and non-UInt32 values, refuse without narrowing traps.
No validation reads the engine. Existing document services and captured forms
perform the native commands. No native API, facade or palette context path changed.

## Recorded verification (2026-11-10)

Tests copied into unmodified Main reproduced two missing-submenu failures in
two tests. Corrected production `c505c9c` passes four focused unit tests. An
initial actual pinned run reached 47 checks and recorded two fixture failures:
it incorrectly expected one Undo for the existing native multi-setter attribute
command, and its wait helper consumed a semaphore result twice. That failed
run is preserved. The native implementation already documents separate setter
Undo entries; this change does not group or alter them.

Tests-only `f63ef9b` latches a successful wait and independently measures the
same name/overlay edit on a duplicate image, asserting its two native Undo
entries. The real captured form must match that reference, with B unchanged.
The corrected actual fixture passes all 56 checks on each of four engines,
plus all 1,016 units in a proper private leased run. It exercises actual nil-
target responder routing, A's captured form while B is genuinely front,
full-size selection-mask samples versus independent references for all four
modes, Undo/Redo, selected versus clicked IDs, no/multiple/Quick Mask/stale/
pending/busy/sheet/closing refusals and renderer-held native close.

Each owned process exits0 and releases the desktop. All four immediate final
external AX snapshots report no dialog. The final unit run's snapshot scope is
recorded separately in the JSON receipt. Temporary signed shells load immutable
external API165 producers; they are not self-contained release bundles.

Mask oracles use duplicate-image public thumbnails at full fixture dimensions;
they do not establish raw floating-point selection-buffer fidelity. Actual
floating/preview lifecycle variants remain covered by existing services and
pure gates, not newly executed by this fixture. Independent completed review,
latest CI/merge and final combined release remain gates. Evidence:
`/tmp/glims-completion/channel-menu-f63ef9b-all-four-verification.json`.
