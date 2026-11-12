# Native ink Levels preview

CMYK and Multichannel documents use the selected ink channel's native scalar
samples for Levels. Intensity zero means full ink and one means paper. The
panel exposes input/output endpoints, gamma, and input/output clamping; it
does not convert the document to RGB or attach a layer filter.

The appended facade slots 185–188 capture, preview, apply, and release an
opaque snapshot token. Capture owns a private immutable native image. Each
preview returns a separately owned image; changing or closing that image
cannot affect the baseline or the live document. One private calculation is
cached by all seven Levels settings, so viewport changes do not repeat the
full-plane calculation. The cached image is never exposed by an image ID.

Apply compares the current ordered native planes, including hidden inks,
selection bytes, ink identity, display metadata, and profile with the
captured baseline while holding native edit ownership. A changed source
refuses atomically. The calculation uses the original samples and blends
selection coverage once. Changed output publishes exactly one Undo; an
identity has no history effect. Successful Apply consumes the token. Failed
or canceled Apply retains it for explicit cleanup. Closing the source also
releases all private images.

The canvas runs one preview job at a time and retains only the latest desired
request. Token, viewport, display destination, and proof changes invalidate
old pixels. Apply requires a completed preview matching the current fields.
Invalid live field-editor text cannot apply the last valid values. Cancel
hides the panel immediately and keeps document edit admission closed until
native cleanup completes. Native Begin and cleanup remain counted during
document close.

Recorder displays an explicit unsupported step for an accepted ink Levels
edit. Replay support is separate work; the panel does not silently record a
different RGB operation. This feature does not add native Curves, Lab,
duotone, CMYK-preserving import, or general adjustment/filter parity.

## Verification in progress

The independent snapshot fixture checks exact samples, source and returned
image isolation, repeated requests, settings changes, invalid/foreign
tokens, hidden-ink and selection drift, fractional frozen coverage,
Apply/Undo/Redo, source close, and cancellation/retargeting at the final
publication checkpoint. The expanded fixture passes 662 checks on each of the
four engines, alongside native conformance and prior ink edit suites. Twelve
panel/coalescer unit tests pass, including reproduced and fixed same-request
render/Apply retry failures. Actual panel and standalone checks are ongoing.

A local optimized 12-megapixel U16 probe measured first calculation at
317–320 ms and repeated calculation retrieval at 0.87–1.41 ms after caching
(previously 310–338 ms). Rendering a 512-by-512 viewport separately took
11–23 ms for Multichannel and 60–65 ms for CMYK. These are measurements on
this Mac, not universal latency guarantees. Compare-and-Apply took
345–350 ms. The complete app and fresh-install launch still require final
qualification for this source revision.
