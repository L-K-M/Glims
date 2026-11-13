# Physical Lab Brush

The candidate enables Brush on one selected L*, a* or b* plane. Tool Options
accepts a physical value, size, opacity and hardness. Drafts belong to the
document and axis UUID; changing a draft after pressing the canvas affects
the next stroke. Invalid text refuses painting visibly. Escape cancels the
whole gesture, including dabs still queued. The other Lab planes stay exact.

This uses the native brush geometry and interpolation with a private scalar
paint core. It does not route a Lab value through RGB foreground color or
ink percentage. Resource masks, including changing pipe-brush members, supply
coverage. Pressure-size dynamics are disabled for this initial Lab workflow.
The ordinary RGB brush preference survives retargeting between documents.

## Numeric and lifetime contract

- Slots 193/194 add typed Begin and Cancel; continuation uses the existing V2
  packet and End. Older engines retain Lab Fill and navigation without Brush.
- Begin captures axis ID, canonical role, document-scoped UUID, physical value,
  brush mask and settings. Every write and End revalidates the captured target.
- U8/U16 values use the Lab codec's physical ranges; Float accepts finite
  physical values. Size is 1 through 10,000 pixels. Opacity and hardness are
  finite fractions in [0,1]. The implementation uses Normal, constant painting.
- Generated mask undershoot/overshoot is explicitly clamped to [0,1]. For each
  pixel, coverage is `float(fma(1 - double(old), double(mask), double(old)))`.
  Zero coverage preserves the original bytes. Selection, cumulative coverage
  and opacity blend the physical value against the original stroke samples,
  with one final sample quantization. This is Glims's contract, not a claim of
  Photoshop numeric equivalence.
- A dab stages only its affected rectangle before publication. An invalid
  affected sample publishes none of that dab; the caller cancels the complete
  stroke, restoring earlier dabs as well. Unchanged samples outside the brush
  remain untouched. A changed completed stroke creates one native Undo step.
- Save and Save a Copy refuse a live native Lab stroke before opening the
  destination. Closing the native image cancels its strokes while their image
  is still alive. Engine shutdown and explicit cancellation release ownership.
- The document input queue orders Begin, dabs, End and Cancel. Accepted input
  holds unsaved state until reconciliation, and reentrant admission observers
  cannot overwrite an already accepted stroke handle.

## Verification and remaining scope

The focused facade fixture retains failing evidence for three corrected
defects: subpixel sizes inherited the native default, image close left an
orphan stroke, and Save wrote tentative pixels. All four engines pass 736
facade checks, 308 document-admission checks and the private geometry/pipe
suite. The pure coverage suite passes 133 optimized and 133 ASan/UBSan checks.
Each engine passes 61 queued Swift checks, including reentrant Begin,
stale-axis cancellation and the next successful gesture, plus 90 actual-window
Brush checks and the existing 65-check Lab workflow. The real 192-slot engine
passes three compatibility checks. All 1,598 Swift and 130 Python tests pass.
Independent native, workflow and fixture reviews are clear after their fixes.

A bounded native timing experiment materializes a nonuniform L plane, then
paints the same small brush on 256×256 and 6000×4000 images. Median time for
63 later dabs is 0.871 ms and 0.884 ms respectively; first large-image
initialization is measured separately at 1.158 ms. This measures native dab
work, not pointer-to-screen latency, selection snapshots or arbitrary brushes.

Bundled launch and hosted qualification are still in progress. This does not
enable Lab layers, conversion, external interchange, other paint tools or Recorder replay. It
does not establish complete Photoshop 4 parity or installed-app qualification.

## Recorder capture foundation (candidate)

Additive slot207 captures the actual installed brush identity and a fingerprint
of its mask content and effective physical paint settings in the same call as
Begin. Guarded replay requires an explicit brush and verifies that fingerprint
before the first dab. Live painting with an unrecordable brush still works and
returns no capture facts. Axis ID, role, UUID and selected-target admission
remain separate from resource/configuration identity. The ordinary slot193
path keeps its prior behavior.

The Swift transport checks the optional API prefix, owns returned strings and
preserves V2 optional axes. A separate tablet trace retains accepted batches,
absent versus explicit-zero optional inputs and modular timestamps, with a
bounded total sample count. Recorder capture, file encoding and replay wiring
remain subsequent work; this foundation alone does not enable recorded Lab
brush gestures.

The previous producer fails the new slot207 assertion. The pinned producer
passes 1,268 expanded native checks, including independent old-route versus
capture/replay pixel equality in all axes and precisions, exact Undo, changed
mask/settings refusal, unavailable facts for live noncatalog brushes, and
short/unaligned/future-sized output buffers. All four engines pass these 1,268
checks plus conformance. All 1,702 Swift and 141 Python tests pass. Native
source review and hosted CI remain open; the installed app is unchanged.
