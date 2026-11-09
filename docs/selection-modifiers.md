# Selection drag modifiers

Rectangle and Ellipse Select capture New/Add/Subtract/Intersect when the
pointer is pressed, using the Tool Options mode unless Shift or Option
overrides it. Changing modifiers later keeps that captured operation.
During the drag, Shift makes equal sides and Option uses the press point
as the center. Holding both combines those behaviors. Modifiers already
held at the press also affect the geometry while held.

One pure image-space calculation supplies both the rubber band and the
committed shape. Modifier-only events update a stationary rubber band;
the release uses its final pointer and modifier state. Reverse and
fractional drags keep their coordinates without clipping or rounding.
The native selection operation handles image bounds and antialiasing.
Nonfinite or overflowing geometry is refused before a native command.

Escape during a rectangle, ellipse or lasso drag clears its pending
interaction. Its later mouse release cannot change the selection or
history. This also works while Shift or Option remains held. Tool Options
shows the rectangular/elliptical modifier hint.

The pre-change real-window regression reproduced six ignored Shift/Option
geometry failures across the two tools. The corrected workflow passes21 real-window checks on each supported
engine, and909 unit tests pass (including38 pure geometry tests). Independent
source review reports no important findings. Final integrated packaging
remains a separate gate. This change does not add snapping to selection bounds,
change crop/gradient geometry, or resolve the other completion-ledger items.
