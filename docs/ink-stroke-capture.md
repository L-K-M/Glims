# Ink brush capture foundation

This additive engine foundation supports recording Brush and Pencil gestures
on the selected authoritative CMYK or Multichannel ink plane. Recorder UI and
file integration remain subsequent work; ordinary ink painting already works.
Airbrush retains its existing live route and is not captured by this API.

## Contract

Facade slots 208 and 209 append typed Begin-with-facts and Cancel without
changing API version 1. Begin owns the target's mode, canonical role and UUID,
requires the sole selected ink channel, and reuses the existing component
painter and V2 sample validation. Brush settings retain the existing normalized
RGB-to-scalar ink rule; opacity is independent of that scalar value.

The native brush/configuration fingerprint describes effective scalar ink
painting, not the displayed composite. Guarded replay requires an explicit
resolved brush and matching fingerprint before the first dab. Unrecordable
live configurations may paint with absent capture facts; they must not become
successful Recorder commands. Swift copies and frees native facts and retains
the distinction between absent and explicitly zero tablet axes.

Continue and End revalidate the captured target, including precision, selected
channel and locks. A changed target rolls back the complete tentative stroke.
Explicit Cancel and image close retire the handle without an Undo step; Save
and Save a Copy refuse while the typed gesture is active. The wrapper supports
unaligned known input prefixes and preserves unknown output tails. Older or
partially wired engines are explicitly unsupported by this typed service.

## Validation so far

- A real 207-slot producer fails the missing-capability regression before
  startup or reading the new slots.
- The pinned producer passes 921 native checks across CMYK/Multichannel,
  U8/U16/float and Brush/Pencil. Raw planes match the existing live painter;
  independent Pencil and half-selection oracles check actual values. Replay,
  exact Undo/Redo, target/fingerprint refusal, packet rejection, cancellation,
  Save protection, close and ABI output boundaries are exercised.
- A weak-reference regression reproduced a retained selection buffer after
  cancellation. GIMP's finish path releases that reference, but its cancel,
  cleanup and finalization paths do not. Adapter teardown now releases it;
  the final focused run has no leaked-buffer warning. Upstream is unchanged.
- The pinned general conformance suite and 1,268 Lab brush regressions pass.
  All 1,729 Swift tests and 141 Python tests pass, including eight typed
  transport tests. The desktop test wrapper released its lease.
- The other three engine runs, final delta/fixture review and hosted CI are
  still in progress. This foundation is not installed yet.

The fixture does not establish physical tablet fidelity or every possible
foreign metadata mutation. Cross-precision replay intentionally uses the
destination's native scalar rounding. No layered CMYK/Lab or complete
Photoshop 4 parity claim is made by this slice.
