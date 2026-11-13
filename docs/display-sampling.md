# Alpha-aware display sampling

The profile and proof renderers sample associated linear source pixels before
applying the existing ICC transform. This applies below 100% zoom and between
100% and 200%. Unit and nearest-neighbor magnification retain their direct
path. The legacy sRGB renderer and private layered Lab preview are separate
paths; this change does not qualify their large-coordinate behavior.

## Why the adapter owns sampling

The native projection may store straight, nonlinear samples. Its mipmaps
average those stored samples before a requested format conversion. Transparent
colors then contaminate reductions. Native BOX magnification also reproduced
a missing bottom-right contribution, while forced BILINEAR reads reproduced
invalid output at large coordinates. The adapter fixes these reads without
changing upstream sources.

`display-sample.c` maintains a lazy, associated-linear float buffer in the
source's own Babl space. It associates and unassociates using the actual alpha,
including alpha below Babl's conversion floor. After spatial sampling, the
display renderer encodes the straight result in the source profile's TRC and
uses its existing ICC/proof transform. Source pixels and profiles are untouched.

## Lifetime and invalidation

One cache belongs to each open image. It owns the source and native validator
references. Prepare reuses only an exact match of source identity, extent,
source format, linear format and assigned validator. Changed keys or a sticky
failure replace the cache. Closing stops projection work and frees the cache
before releasing component previews or the image.

Reads are serialized on the engine thread. Projection work is stopped/flushed
before preparing a read epoch; writes, asynchronous jobs and nested reads of
that sampler are forbidden until it ends. A per-image active flag refuses
reentry, while a balanced global busy increment prevents writes. Existing
global busy state alone does not refuse viewing during a plug-in dialog.

Source damage uses `gegl_buffer_signal_connect`, which enables GEGL's changed
emissions, plus the native validator's invalidated signal. Callbacks only
accumulate clipped damage under a mutex. The read validates its source
footprint before draining damage and validating derived pixels. Direct writes,
lazy projection invalidation and source replacement have independent controls.

## Bounds and arithmetic

Integer tile coordinates avoid native floating ROI rounding. Standard-center
bilinear interpolation operates on associated mip samples. Exact dyadic scales
read the corresponding mip row directly. Native mip levels through four are
reused; deeper levels average only intersecting level-four cells in double
precision, dividing by the complete coarse cell area, including transparent
abyss. This prevents exponentially visiting empty descendants at minimum zoom.
Its rounding can differ from native recursive float mipmaps.

The existing scale, coordinate and 512 MiB output bounds remain. Per-read
scratch uses fixed rows and the display renderer's 16 MiB chunk cap. GEGL's
lazy cache can retain source-sized float tiles; bounded scratch does not mean
a source-independent cache size. Finite signed and extended color values are
preserved until the SDR transform. Nonfinite or unrepresentable results fail;
float association can underflow, and extreme native float mip sums can
overflow. Runtime failures can leave earlier scratch chunks written, which
the caller discards. See `Engine/display-sample.h` for the private contract.

## Canvas retry

A typed transient BUSY result keeps cached tiles and schedules one cancellable
retry. Delays grow from 50 ms to a one-second cap. Success, generation changes
and shutdown reset the delay and invalidate queued callbacks. Other failures
retain the existing permanent-error path. Six deterministic scheduler tests
cover retry admission, cancellation, lifetime and delay bounds; they are not
physical-input or full-window acceptance tests.

## Verification

`scripts/test-display-sampling.py` links its native fixture against an existing,
attested adapter producer and verifies that inputs remain unchanged. The
fixture covers independent RGB/Gray ICC and spatial expectations, transparency,
signed values, proofing, cache damage and replacement, large positive/negative
coordinates, minimum zoom, state preservation and busy admission. A separate
facade-only 24 MP timing probe measures cold, cached, edited and undone reads.
Final engine-matrix and app results are recorded in `docs/plan.md`.
