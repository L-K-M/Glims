# Painting on structured layers

Painting, fills, gradients and the other document commands using
`runOnPaintTarget` require an ordinary or already rasterized layer. Painting
an editable text, linked or vector layer opens Rasterize/Cancel in its owning
window. The refused gesture changes no pixels or history. The prompt explains
that Rasterize preserves the source and that the user must draw or apply the
command again. Pointer events are never replayed after a modal sheet.

Rasterize uses the existing explicit layer command and adds its own Undo
step without changing pixels. Subsequent painting is a separate Undo step.
Layer > Restore Layer Source remains the explicit inverse that discards
pixel edits and regenerates the retained source. Masks and channels keep
their own paint targets and do not require rasterizing an owning layer.

The prompt captures its document, explicit layer and document version.
Apply refuses changed selections/targets/versions, queued work and closing
windows. Ending pending field edits can itself enqueue work, so the document
checks the captured paint state again after that callback. The window owns
and cancels the alert when it closes. Every admitted pixel command also reads
fresh native source state behind accepted input; an earlier Undo cannot
silently restore editability behind the main-thread cache and then receive
paint. Missing source reads fail closed. No native call runs on the main
thread to validate a pointer event.

The explicit step also avoids a measured native Undo/Redo problem. An
editable text layer painted directly through the facade loses its painted
pixels after Undo/Redo on GIMP3.2.8,3.2.0 and master;3.0.8 preserves them.
The native text-layer Undo first restores the rasterized flag, rerendering
the original text before drawable Undo stores the live painted pixels.
The external observation probe records retained text, raw pixels, projection
pixels and history independently. Explicit Rasterize followed by painting
preserves the exact painted pixels through Undo/Redo on all four engines.
No upstream patch or facade behavior change is made by this UI policy.

The actual-form regression reproduced absent consent and mutated native state
before the fix. Separate held-input and held-render regressions reproduced
late Rasterize acceptance after queued work and after window closing; both
pass with the captured-state and close guards. Additional acceptance checks
and the integrated release run are recorded with the candidate's validation.
This seam does not establish consent for every destructive operation or
complete the Text tool's source-restoration interactions.
