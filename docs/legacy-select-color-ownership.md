# Legacy Select Color source-buffer ownership

GIMP 3.0.8's `app/core/gimppickable-contiguous-region.cc` obtains an owned
`src_buffer` through `gimp_pickable_get_buffer_with_effects()` in both
`gimp_pickable_contiguous_region_by_seed()` and
`gimp_pickable_contiguous_region_by_color()` (lines147 and225), then returns
without releasing it. The Pickable dispatcher either calls an owned effects
getter or references the borrowed buffer getter. A drawable with committed
effects can return a newly materialized buffer. Supported 3.2.0 and 3.2.8
already release `src_buffer` and must not compensate.

`Engine/select-color-legacy.c` applies only when the compiled engine's major,
minor and micro versions are exactly 3.0.8. It flushes the actual source and
materializes its owned post-effects buffer once. A private GimpObject
subclass implements GimpPickable, including its readable `buffer` property;
GimpObject is the interface's required base type. Its effects getter returns
an owned reference and counts each reference issued to the unchanged native
region algorithm. After that synchronous algorithm returns, the helper
balances exactly those omitted references and releases its proxy/base
ownership. It neither reads raw refcounts nor changes native interface tables.

`Engine/select.c` applies the returned mask with the original native Undo
description, offsets, operation and feather settings. Existing point/color
sampling remains intact, including the by-color sample taken before invoking
the algorithm. The original buffer retains its native format, color space
and extent. Missing buffers or failed mask creation release owned inputs and
return without applying a mask. Modern engines retain their native channel
selection calls. No upstream source or public facade slot changes.

## Verified behavior

Runtime results below apply to production source
`671b916697818cfd500d3e5378d7d7c3b16e1a75`:

| Producer | Ownership cases | Observed source buffers after close/shutdown |
|---|---|---|
| Original 3.2.8 control | 12 pass | All observed buffers released |
| Original 3.0.8 | Four zero-selection controls pass; eight nonzero cases fail | Exactly one/two buffers survive one/two selections |
| Patched 3.0.8 | 12 pass | All observed buffers released |

The separate ownership harness uses zero/one/two selections on fresh images,
contiguous/by-color and merged/layer sampling. Weak callbacks watch actual
returned buffers without retaining them. Zero-selection cases still observe
a real baseline source. Test-only getter wrappers restore before image close;
callback flags remain valid through engine shutdown. Acceptance uses object
lifetimes and call counts, not RSS or diagnostic wording. The original
ownership oracle is unchanged by the production fix.

Patched 3.0.8 also passes 1,703 conformance checks. The parity harness captures
every selection-mask sample as float bytes, plus Undo metadata, before/after/
Undo/Redo from an immutable original producer, then compares the patched
producer: all 128 files match exactly across 16 asymmetric RGBA fixtures. These cover both
selection modes, merged/layer sampling, positive/negative offsets, hard and
antialiased+feathered selection, and retained committed effects. Operations
cycle through all four; this is not their full cross-product. Antialias and
feather are paired, and the fixture does not establish every source format,
effect, offset or threshold combination.

Harnesses: `Engine/tests/select-color-{ownership,parity}-tests.c`; separate
build/run/compare drivers: `scripts/test-select-color-{ownership,parity}.py`.
Drivers preserve selected producer objects and use private settings/temp
directories. Modern-engine validation of the patched source and independent
review remain pending. No release or wider completion claim follows from
these focused results.
