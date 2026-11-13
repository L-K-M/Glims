# Private transparent Lab layer creation

The private command inserts one logical root at an explicit index, including
into an empty carrier. It appends five fresh map identities and selects the
new root. Its full-canvas scalar planes start at L=255, a=b=128 and alpha=0;
the root is visible, opacity 1 and Normal. Empty names default to "Layer";
nonempty names must be valid UTF-8 of at most 1,024 bytes.

The native group and children are constructed while detached. Their
parentage, identity parasites and raw scalar fills are prepared without
changing the image's tree or selection. The replacement map, selection
vectors and exact insertion preflight precede native history mutation.
One native Undo group records insertion, the map and a final selection
companion. Undo restores the prior tree, map and ordered selection; Redo
retains the created objects and UUIDs.

Review caught an empty-selection edge: native removal treats a NULL prior
selection as permission to choose a surviving root. A native probe failed
one of eight checks before the fix. The final companion runs first on Undo
and explicitly restores the prior selection before native removal. The
same probe then passes all eight checks, and the independent fixture covers
empty, plural and scalar-child prior selections.

The independent final matrix passes 329 checks per engine, 1,316 total.
Six creation/XCF scenarios verify exact start/middle/end insertion, raw
initial values, fresh identities, preservation of existing items and masks,
actual Redo clearing, repeated Undo/Redo, UTF-8 and boundary names, and
native XCF raw/map/name/attribute persistence. Refusal snapshots include
history and dirty state; the 255-to-256 boundary is tested. Source review
found no remaining important issue after the selection correction.

Evidence is under `/tmp/glims-lab-layer-create`; the separate failure and
correction probes are `/tmp/glims-lab-layer-create-empty-red` and
`/tmp/glims-lab-layer-create-empty-green`. Attested inputs remained unchanged.
Earlier 311-check and revised pinned runs are separate from the final matrix.
Recorded older-engine/master diagnostics remain in their raw logs.

The caller must serialize the complete operation and exclude native writes,
validation, nested dispatch and external mutation. Ordinary refusals happen
before history changes. Unexpected commit/fatal failures are reported
without promising rollback; normal native history retention is unchanged.
These optimized native tests do not prove arbitrary allocation-failure or
concurrency behavior. The returned root is borrowed until a later edit or
Undo. This private primitive does not yet enable public layered editing.
