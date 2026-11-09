# Adjustment group creation (slot 130)

The backend creates an empty pass-through group with one committed native
filter at its default parameters. This is a committed creation command;
parameter editing uses the existing filter-edit preview/Cancel/commit flow.
Only allowed one-input operations with generic parameters are admitted.
Custom native configuration objects and auxiliary images remain separate.

All input and recoverable object construction checks run before the native
Undo group. Creation records layer-add followed by filter-add in one native
group: Undo removes the filter before its drawable; Redo adds the drawable
before reapplying the filter. Preparing a detached group and recording only
layer-add reproduced a removed group with stale black projection pixels.
The corrected ordering passes the pinned native probe: one Undo, white after
Undo, black after Redo, and black after XCF reopen.

Primary references are the pinned engine's `app/core/gimpimage.c`
(add/remove-layer), `gimpdrawablefilter.c` (ND commit and drawable removal),
`gimpimage-undo-push.c` (filter-add), and `gimpdrawablefilterundo.c` (pop).
The relay's source investigation corroborates the inverse ordering; it did
not execute code or prove the exact original projection invalidation path.

The public bridge resets both available outputs before dispatch, including
NOT_RUNNING. Explicit parent/index, image ownership, floating/active-edit
refusals and operation support are validated. No upstream files change.
An unexpected internal add failure after group-start can affect dirty/history
state; this API does not promise a general multi-step transaction guarantee.

The initial standalone harness needed acceptance corrections: safe ABI
footer checking, bounded successful snapshots, an actually clean baseline,
independent effect visibility checks after the creation Undo oracle, and
editing an adjustment's actual effect rather than an unrelated raster.
A pre-dispatch NULL-engine check reproduced the output-reset error in the
older producer. The final four-engine matrix passes all 91 standalone checks
per engine and the general 1,917 / 1,703 / 1,917 / 1,917 native checks.
No creation UI is wired yet.

The oldest engine exposed two more failures: modified-filter preview kept
white pixels despite a brightness value of -3, and Undo retained black
pixels despite a restored value of 0. Opening a fresh edit also showed the
correct restored value. A 3.0-only compatibility hook invalidates the image
projection after filter preview/commit and Undo/Redo when a pass-through
group holds filters. Lazy reads still render requested tiles; rendering
itself never calls this hook. It changes no image data or history. The same
91 checks now pass on 3.0.8, including preview and Undo pixels.

Independent implementation and compatibility code-safety reviews found no
important issue. A separate attempt to trace the precise native cache
mechanism timed out without a verdict. The runtime mismatch and corrected
pixels are established; the exact upstream invalidation path remains an
investigation gap. Whole-image invalidation has a cost on the affected old
engine, bounded to mutations in images containing these groups.
