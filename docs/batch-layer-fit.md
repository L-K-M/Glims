# Captured layers to image size

Layer > Layers to Image Size and the Layers palette operate on the complete
ordered layer selection captured when the command is accepted. They resize
each selected pixel layer to the image bounds at 0,0 with transparent fill;
Native Core resizes each layer's mask with it. Existing pixels keep their
image coordinates inside the canvas. Pixels outside the canvas are cropped,
and Undo restores their original extent and bytes.

The command admits 1…256 distinct pixel-behaving layers, including previously
rasterized source instances. Groups and genuine editable text, link and
vector sources refuse the whole request. Every ID, attachment, effective
pixel/position lock, floating-selection state and Undo admission is checked
before the first resize. A locked or stale later member cannot resize an
earlier member. Alpha-only locks are preserved and do not refuse the command.
The native selected-layer order and tree topology remain unchanged, even if
selection changes after the request is queued. An all-already-fit request
adds no history or dirty change; otherwise one native Undo group covers all
changed targets. The native void-return resize is not an allocation-failure
transaction.

API v1 appends slot 156. The app's typed wrapper validates the vector and the
captured document queues the accepted job behind pending fields/strokes.
Counted completion and reload use the existing target-command lifecycle, so
closing waits for accepted work and completion runs once. Menu and palette
eligibility share the cached kind/lock policy; validation never calls the
engine. Existing single-layer Fit and Trim behavior is retained.

Verification:

- All 964 unit tests pass, including eight cached policy tests.
- Each supported engine passes 145 focused native checks: exact world-space
  layer/mask bytes, nested/root targets and untouched siblings, selection,
  alpha locks, maximum 256 no-op, invalid inputs, readiness, clean Undo/Redo,
  retained rasterized Text and host-thread facade dispatch.
- Each engine passes 21 actual UI checks, including real main/palette actions,
  captured-document targeting, a later native selection, a late second-layer
  lock, pending target refusal, exact completion and close drain.
- General native checks pass 1,917 on each 3.2/master build and 1,703 on 3.0.8.
- The self-contained bundle passes 1,917 native and 2,542 app checks with native
  and Swift build outputs inaccessible. The full run first caught the old
  test's single-layer Fit assumption; it now exercises the still-single Trim
  refusal and explicitly validates plural Fit admission. The updated focused
  and full runs pass.
- Independent native and UI source reviews have no important finding. Final
  PR CI and merge remain pending.

The broader batch/gesture-policy work remains open. This does not introduce
batch Trim, Move/Transform, source conversion or blanket rasterization.
