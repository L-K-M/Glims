# Native filter color controls

GIMP Colorize, Offset and Semi-flatten use GIMP's color parameter spec,
which derives from its object-default spec. Treating only GEGL color specs
as colors left these native properties unsupported. The adapter now reads
the GIMP spec's virtual default through an owned GValue and reuses the
existing typed color transport, validation, Get and Set. The GEGL default
path stays unchanged. No facade slot or layout changes.

The form acknowledges actual operation values rather than echoing its
request. For example, Colorize reconstructs its color from HSL, changes
all three scalar peers when a color is set, and returns alpha 1. A later
scalar edit also changes the color well.

The document writes and reads all requested properties in one counted
serial input job. The answer distinguishes a refused write from a read
failure after an accepted write; the latter does not claim rollback.
Actual readbacks update the accepted cache. Pending field generations
protect newer queued edits, and the existing draft helper preserves newer
uncommitted text and its selection. A refused field restores its accepted
value without overwriting text entered after that request. Retired panels
ignore callbacks, and Close still waits for accepted work.

## Verification

The original native fixture failed nine metadata/Get/Set assertions, with
its independent operation graphs and native defaults passing. The real
Colorize form then failed four acknowledgement assertions despite the
native HSL and alpha controls passing. These are separate baselines.

| Engine | Focused native checks | Actual form checks | General native checks |
|---|---:|---:|---:|
| GIMP 3.2.8 | 59 | 16 | 1,917 |
| GIMP 3.2.0 | 46 | 16 | 1,917 |
| GIMP 3.0.8 | 59 | 16 | 1,703 |
| master | 59 | 16 | 1,917 |

All pass, totaling 223 focused native, 64 actual form and 7,454 general
native checks. GIMP 3.2.0's native filter gate rejects Offset: its fixture
checks that metadata and Begin preserve that refusal and leave the image
unchanged. Newer engines have a native Offset exception; the existing
3.0 compatibility gate also allows it. No production gate is widened.

Native expected colors and rendered pixels come from independent same-op
GEGL graphs and GLib default GValues. Apply, Cancel, one Undo and Redo are
checked. The actual generic form exercises native HSL/alpha readback,
refusal, queued stale acknowledgements, a real uncommitted field editor
and selection, later draft commit, and complete teardown. All 1,216 unit
tests pass on the Main-integrated source. Each owned GUI process exited
and released the desktop without a remaining dialog.

Native production `3136ee5` and Swift production `f9ee625` each received
an independent source review with no important finding. The integrated
runtime source is `9e9f25c`; its later changes are fixture compatibility
and Main's Revert test/documentation integration. General 3.0.8 output
retains the earlier two-buffer leak diagnostic, and master retains a
cache-XML cleanup diagnostic; neither is claimed fixed here.

These are focused temporary-host and source-adapter checks. A final
combined standalone release, public signing and physical display checks
remain separate gates.
