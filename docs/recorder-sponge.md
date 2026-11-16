# Sponge stroke recording

This candidate extends native stroke capture for the Sponge Desaturate and
Sponge Saturate tools on ordinary RGB pixel layers, including opaque Background
layers and layers with alpha. A captured gesture binds the effective brush and
supported paint configuration as before. Its new fingerprint distinguishes
both Sponge directions and whether the target has alpha, so changing either
refuses guarded replay before the first dab. Ink channels, masks, groups and
other unsupported stroke configurations continue to refuse capture; an ordinary
live stroke can still complete when no Recorder facts are available.

Mouse capture uses the existing V1 stroke samples; tablet capture uses V2
samples, including optional rotation and tangential pressure. Replay uses
the destination image's current selection and pixels, just like other ordinary
recorded strokes. It does not promise identical output on different engines or
with a different starting image. Older engines can still paint live tablet
strokes but report an unsupported recording rather than losing those axes.

The native fixtures compare independently seeded ordinary strokes against
capture and guarded replay, including raw and merged pixels, alpha-bearing
and opaque targets, both directions, opposite-direction and cross-alpha
refusals, and Undo/Redo. The existing Pencil/Eraser and Paintbrush capture
fixtures check the earlier fingerprint behavior. Separate real-window tests
record normal and opaque-background Sponge strokes through the canvas, save
and reopen the versioned file, and check Undo and guarded replay; older
adapters without Sponge capture are refused. These checks do not qualify
physical tablets.
