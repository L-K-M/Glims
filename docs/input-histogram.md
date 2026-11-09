# Input histograms and automatic Levels

Levels and Curves show the input distribution for their captured drawable.
Changing the displayed channel or the histogram's linear/logarithmic scale
changes only the view. Refresh repeats the captured input read. Accepted
transfer-curve changes reload the distribution and discard older replies.

The histogram uses the drawable's pixels before filters, weighted by the
image selection and source transparency. It excludes layer opacity and layer
mask composition. Value is the largest RGB component; it is distinct from
luminance. Alpha counts selection coverage without multiplying by alpha.
Grayscale sources expose Value and, when present, Alpha. Native bin counts
remain256 for8-bit input and1024 for higher precision; empty intersections
have no bins. Finite negative weights from out-of-range HDR alpha are kept,
including in signed logarithmic drawing.

Auto Input Levels follows the native Levels tool: a fresh histogram in the
current transfer curve drives the0.006-tail input stretch. Color sources
reset Value and stretch RGB independently; grayscale stretches Value.
Stretched channels get gamma1 and output0..1. Alpha, transfer curve, clamps,
access cursor and base settings remain unchanged. The settings replace a
private configuration and are returned in full before the UI updates.

Auto finishes numeric editing and waits for every preceding write's
acknowledgement. A refused field prevents Auto, including synchronous and
asynchronous refusals. Parameter controls and Apply wait for the unknown
result; Cancel remains available. The counted document queue preserves the
captured preview and holds reads through deferred idle replies and closing.

## Adapter contract

Facade version1 appends slots161..163: owned histogram Get, heap-only Free,
and Levels Auto. Six owned channel flags and independent double arrays keep
native enums/objects inside Engine. Output validation, partial-allocation
cleanup and Free preserve struct_size and future caller tail bytes.
Read-only histograms remain available under pixel locks; Auto follows the
ordinary preview edit gate. Stale, closed, busy and unsupported sessions
refuse explicitly. Source pixels, selection, target and native history are
unchanged by reads and parameter previews; Apply retains native Undo.

Calculation is synchronous on the dedicated engine worker. It neither runs
on AppKit's main thread nor retains an asynchronously mutable native object.
Only validated complete results reach the forms. All four supported Core
implementations share the calculation and stretch bodies; the explicit
current configuration TRC avoids differing native constructor defaults.

## Acceptance checkpoint

977 unit tests pass. Each supported engine passes78 dedicated native checks,
19 actual-form checks, plus the previous Levels21 and Curves32 interface
regressions. Native checks use fixed pixel/bin/selection/HDR literals and
actual Apply, Undo/Redo, Cancel and XCF reopening. General checks pass1917
per3.2/master engine and1703 on3.0.8. A synchronous final-field refusal was
reproduced with one failing UI assertion before the preparation barrier was
corrected. Both panels fit the actual test display. Independent native and
UI source reviews have no important remaining findings. The final bundle
and hosted CI are pending.

These results do not close the separate raw-HDR XCF identity/composite
persistence work or the remaining whole-editor completion ledger.
