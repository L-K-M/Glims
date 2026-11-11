# Numeric layer transforms

The Transform tool's options show X, Y, Width and Height in image pixels,
and Angle in clockwise degrees. These values edit the same pending preview
as the canvas handles. Width and Height keep the unrotated box's X/Y origin;
rotation is around that box's centre. Angles normalize to (-180, 180].

Return in a field updates the preview. Apply commits the pending transform
as one native Undo step; Cancel discards it. Escape in a field discards only
that field's draft. Unfinished or invalid text remains visible after focus
loss and blocks Apply. A draft belongs to its captured document, layer and
transform lifetime, so changing selection or documents cannot apply it to
the new target. Ending Apply also ends the old field editor's lifetime.

The options scroll when the palette is too short. This also keeps existing
tool controls reachable without compressing rows to zero height.

Numeric admission rejects non-finite values, sides below one pixel,
unsafe coordinates, singular matrices and excessive rotated output bounds.
Mask/channel editing, floating selections, locks, multi-selection and
pending engine work follow the existing transform admission policy.

Focused tests cover geometry, captured draft identity, invalid/stale text,
and control accessibility and visibility. The `numeric-transform` native
smoke case types through real AppKit field editors, checks Apply/Cancel and
selection changes, and compares exact pixels and bounds through Undo/Redo.
This adds typed scale, position and rotation; skew, distortion and
perspective remain separate work in the editor completion targets.
