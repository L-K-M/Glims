# Private layered Lab preview

The derived preview reads the validated U8 Lab layer carrier. It does not
admit layered documents through the facade or enable editing controls.
Native L/a/b/alpha samples, layer order and attributes remain authoritative.

## Ownership and updates

`lab-layer-preview.c` owns a derived GEGL buffer and references to every
source plane, including hidden and zero-opacity layers. Each prepare freshly
validates the carrier and compares map identities, root order, visibility,
opacity, dimensions and buffer identities. Changed bindings rebuild the
cache. Same-buffer writes accumulate clipped damage; prepare invalidates
that area before the next read. Failed validation is reported explicitly,
and the following prepare invalidates the full extent for a retry.

Prepare, reads and destruction are serialized on the engine thread. All
source writes must finish before a complete validation/read epoch begins.
The borrowed diagnostic buffer must never be attached to a GEGL graph or
used by parallel/asynchronous readers. A narrow row mutex does not grant a
worker-thread contract. Disposal requires quiescence, not merely a lock.

## Sampling and transparency

Rows are composited in physical Lab and converted to straight linear sRGB.
Both native validation callbacks then multiply color by actual alpha and
store `RaGaBaA float`. Babl association is deliberately bypassed because its
alpha floor changes colors at very small coverage. Native sample bytes are
not modified; derived float storage can lose precision at tiny alpha.

`lab-layer-preview-read.c` keeps values associated through spatial sampling,
then divides by positive alpha in double precision. Alpha zero becomes
canonical positive-zero RGBA. No gamut clipping, transfer curve or ICC
conversion occurs in this helper. Display conversion must consume its
straight result and premultiply only after the destination transform.

Below 1x and between 1x and 2x, the shared display sampler uses global pixel
centers: source position `(output + 0.5) / scale - 0.5`. It interpolates
associated mip samples before unassociation. Native mip levels through four
are reused; deeper levels average intersecting level-four cells in double
precision over the complete footprint, including transparent abyss. Unit
scale and nearest magnification at 2x or greater retain their direct paths.

This bounded sampler avoids two reproduced native magnification defects:
AUTO/BOX can discard a contributing bottom-right neighbor, and forcing the
native BILINEAR path on a wide magnified read returned invalid values.
Native BOX also changes low-alpha rounding with request partitioning.
No upstream source is patched. Literal rational corner/seam controls and an
independently structured bilinear reference qualify the adapter behavior. At
the minimum supported scale, a small Lab carrier previously caused an enormous
native allocation and process abort; the sparse deeper-level path avoids that
native traversal. Integer mip coordinates also avoid native float ROI rounding.

The preview owns a second lazy associated-linear sampling cache, freed before
the preview buffer. Its source-validator and buffer damage signals invalidate
the derived tiles between serialized read epochs. One-column unit reads still
explicitly validate level zero to avoid a stale hot tile; other unit chunks
avoid a final one-pixel request. Scratch storage is bounded independently of
image dimensions; lazy GEGL caches may retain source-sized tiles. Invalid
arguments preserve the output; callers discard all output on runtime failure.

## Evidence

The native runner links immutable producer objects only after verifying their
header ABI and input hashes. It uses an isolated home and a process deadline.
The independent fixture checks transparency, sub-floor alpha, literal corner
and seam values, source damage, hidden layers, attribute/order changes,
replaced buffers, malformed metadata, empty stacks and source-state
preservation. Runtime results and retained failing probes are under
`/tmp/glims-lab-layer-preview`; timing experiments are separate under
`/tmp/glims-lab-layer-preview-perf`. The linked-producer runner
`scripts/test-lab-layer-preview-linked.py` runs the current fixture against
attested adapter objects that already contain the preview implementation.

No public document adoption, editing, export, display-profile integration or
whole-editor qualification is claimed by this private module.
