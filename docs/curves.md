# Curves

Curves has a dedicated modeless form under Image > Adjust and in the native
Filter catalog. It edits Value, Red, Green, Blue and Alpha independently.
The selected channel is view state. The transfer curve applies to the whole
native effect; new effects explicitly use Perceptual on every engine.

The graph supports point insertion, selection, dragging, arrow-key nudges,
Delete and Escape to cancel an unfinished drag. Numeric controls provide an
exact point index, input/output values and Smooth/Corner point types.
Freehand mode paints a complete 256-sample table and also permits exact
individual-sample edits. Converting Freehand to Smooth follows Core's
nine-point sampling rule. Reset uses Core's channel reset and returns to
Smooth. Core's final dirty notification determines the identity shortcut;
Glims does not impose a different HDR bypass policy.

Writes target the captured document and preview session through its counted
input queue. Apply includes active numeric fields before committing one
native Undo step. Cancel restores the accepted image/effect. Existing effects
reopen in the same form. Pending patches belong to individual channels or the
global transfer curve; their native replies cannot replace a newer draft in
another channel. Mode conversion requires an authoritative sample table.

## Native representation

Facade version1 appends slots157..160: Get, Free, one-channel Edit and global
TRC Set. Snapshots contain mapped owned enums, point arrays, sample arrays and
an explicit identity flag for all five channels. No native object, enum or
layout crosses the facade. The caller frees each snapshot before reuse.
Get/Free preserve struct_size and future caller tail bytes. Changed writes
allocate their complete authoritative result before replacing the live config.

Smooth patches carry ordered finite points in [0,1], including their types;
Core generates the sample table. Free patches carry exactly256 finite samples
in [0,1]. Zero or one Smooth point and equal input coordinates retain Core's
semantics. There is no implicit sorting or clamping. The adapter imposes an
explicit65536-point allocation limit; it is not a native Core limit. Imported
non-256-sample curves are refused without normalization or mutation.

Ordinary native configuration duplication can recalculate Smooth tables.
Glims validates a private duplicate's object/storage independence, restores
all admitted source sample tables and identity flags through actual Core
fields, and then edits only the chosen channel. Untouched channel arrays,
access cursor, base settings and source config remain unchanged. A numeric
no-op preserves the installed object and imported noncanonical sample table.

Levels and Curves share exact operation/config TRC validation and installation.
On3.2/master the replacement binding is staged without synchronizing the live
target; only then is the old binding detached and the new config installed.
On3.0 an explicit operation TRC update provides the equivalent coherence.
A legacy mismatch is refused on read/copy/commit rather than silently repaired.
Generic operation-only TRC writes are refused.

## Verification status

The implementation is under acceptance. Native fixtures cover independent
pixel literals, complete snapshots, immutable channel updates, real preview,
Cancel, Undo/Redo and XCF reopening. A missing new/existing Begin admission was
identified during review; three disabled/frozen/grouped-Undo assertions failed
before the guard was added. The expanded dedicated harness passes147 checks on every supported engine.
The general adapter suites pass1917 checks on3.2/master and1703 on3.0.8.
972 unit tests pass. 32 actual-form checks pass on every engine, including graph keyboard edits,
Escape, Freehand painting, channel reset and transfer-curve changes. The
final self-contained release passed1917 native and2574 app checks with build
trees inaccessible. Hosted Xcode26 CI passes after an explicit Double
conversion for Swift6.2. PR136 is merged; the promoted Main app passes74
focused checks with its candidate checkout and source/build inputs blocked.
Final whole-editor acceptance remains open.

Native XCF deserialization does not preserve the identity shortcut flag.
Normalized rendered-file checks therefore do not prove arbitrary raw HDR
bypass preservation. That remains explicit higher-precision/file verification
work in the completion ledger.
