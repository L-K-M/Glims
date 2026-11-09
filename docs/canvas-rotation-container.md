# Canvas view rotation

The document scroll view hosts `CanvasRotationView`, which rotates the existing
flipped canvas with AppKit's `frameRotation`. View ▸ Rotate View offers 15°
clockwise/counterclockwise steps, a fractional angle form and reset. Nonzero
angles appear in the window title. Rotation belongs to each window; image
pixels, native history and file data are unchanged.

AppKit rotates point conversion, hit testing and the existing image-space
canvas, overlays and text editor together. The host offsets the converted
canvas bounding box into positive coordinates. Synchronous frame notifications
update it during zoom/backing changes, with a reentrancy guard and observer
cleanup. Zoom and backing changes preserve the image-space viewport center;
Fit Image uses the rotated extent.

The rulers stay on the screen axes and project the rotated canvas extent.
This follows the equal-resolution pixel-ruler behavior in pinned GIMP commit
7addd2b, `app/display/gimpdisplayshell-rulers.c`. A horizontal ruler still creates
an image-horizontal guide; the coordinate event passes through native view
conversion. View rotation does not change the user's ruler visibility choice.

Actual rotated rectangle gestures exposed affine roundoff at exact pixel edges:
11.99999999999999 expanded a selection to pixel11. CanvasGeometry removes only
noise within1e-7 image pixels of an integer; genuine subpixel input is preserved.
The failing runtime checks now select exact12,14,30,24 bounds at90°,−45°,180°.

Verification:831 unit tests pass. The real engine smoke case `canvas-rotation`
passes on all four supported engines: known-color rendered quadrants, event
mapping, projected rulers, fit/zoom center, native pixel/history preservation,
menu actions/title, invalid and fractional custom-angle forms, actual rectangle
selection, pencil strokes and one-step Undo, rotated ruler guide creation and
screen-relative Hand panning. The container's unit tests also
cover rotated native hit testing outside the unrotated frame, resizing, finite
angles, observer lifetime and absence of a deferred notification loop.

The full app regression passes2237 checks. Independent review found a
fractional visible-tile interval bug: subtracting one from an exclusive
fractional edge could produce0...−1 or omit a partially visible next tile.
The corrected floor/ceil half-open tile range has direct boundary, sliver and
invalid-input tests; independent source inspection of the correction found no
further important issue. All four focused runtime cases pass after that fix.
Hosted CI is pending. Physical movement between displays is not newly verified.
