# Lab fill row

`Engine/lab-fill.{h,c}` provides `glims_lab_fill_row`, a bounded pure-C11
helper that blends a constant physical Lab value into one encoded sample row
using the existing `Engine/lab-samples.{h,c}` codec (unmodified).

## API

```c
bool glims_lab_fill_row(GlimsLabRole role,
                        GlimsLabFormat format,
                        double physical_value,
                        double opacity,
                        size_t count,
                        const void *source,
                        const float *mask,
                        void *destination,
                        bool *changed);
```

- `count <= 4096`, no heap allocation, no I/O. A bounded stack staging buffer
  (`4096 * 4` bytes) is used so all validation completes before any destination
  write and so in-place calls are safe.
- `changed` is required and non-NULL. It is cleared to `false` on invalid
  settings when it can be proven not to alias the provided source/destination/
  mask ranges; if `changed` is NULL or aliases a protected sample/mask range
  (including mask-vs-changed) the call is refused without writing `*changed`.
  On success `*changed` reports whether any output byte differs from the
  corresponding **source** byte (not from the destination's prior contents).
- `count == 0` permits NULL `source`, `destination`, and `mask` but still
  validates `role`, `format`, `physical_value`, `opacity`, and requires
  `changed`; it returns success with `*changed == false`.
- `physical_value` must be finite. Integer targets must be in nominal ranges
  (`L` in `[0,100]`, `a/b` in `[-128,127]`); float targets must satisfy
  `fabs(physical_value) <= FLT_MAX` (extended finite values allowed).
- `opacity` must be finite and in `[0,1]`.
- `source`/`destination` must be non-NULL when `count > 0`. `mask == NULL`
  means 1.0 for every sample. Every mask value, when present, must be finite
  and in `[0,1]`, even when opacity is zero.
- `source` and `destination` may be the same range (in-place). Any other
  overlap between source and destination ranges is refused. Overlaps between
  source/destination ranges and `mask` or `changed`, and mask-vs-changed, are
  refused. Checked `uintptr_t` address ranges are computed before writes or
  dereferences to avoid overflow/UB. Scalar source, destination and mask may be unaligned.
- Invalid format or count above 4096 declares no accepted sample range. These
  settings fail without buffer access; only exact pointer aliases with changed
  can be protected before a valid sample extent exists. Other such failures
  clear changed. Full range alias protection requires valid format/bounded count.

## Blending arithmetic

All arithmetic is in binary64 (`double`) under the default round-to-nearest
floating-point environment, with no fast-math reassociation. The kernel does not
change the calling thread’s rounding mode.

- Effective weight: `w = (double)opacity * (double)(mask ? mask[i] : 1.0f)`.
- `w == 0.0`: copy raw source sample bytes to output (including encoded NaN or
  `-0.0` for float); the affected source sample is not required to be finite.
- `w > 0.0`: decode/validate the affected source sample as a finite physical
  value `p_i` for the role/format (integer encodings per `lab-samples` scales;
  float via `memcpy` load, must be finite).
- Blend: `out_i = fma(w, v, (1.0 - w) * p_i)` where `v` is `physical_value`.
  Binary64 roundoff outside the mathematical convex interval between `p_i`
  and `v` is repaired to its nearest endpoint. This prevents valid equal-endpoint
  fills from being refused one double ulp above FLT_MAX; it does not clip a Lab
  gamut or nominal range. Full weight (`w == 1.0`) writes the exact requested endpoint `v` (no
  cancellation through `p_i`).
- Encoding: float stores `out_i` by C conversion to `float` with no clipping
  (result must remain finite and `<= FLT_MAX`). Integer formats encode once
  using the reviewed mathematical nearest-integer quantization with half values
  rounded up (by calling the existing `glims_lab_encode_row`); no claim of
  exact Photoshop compatibility.

The numerical contract is physical binary64, not raw-code interpolation. For
example, U8 Lightness code 128 decoded to `0x1.9191919191919p+5`, then blended
halfway to 100, yields `0x1.2c64646464646p+6`. Its exact represented-double
quantization is 191 rather than the ideal raw-code midpoint 192. This behavior is
covered by an independently calculated golden and is not a Photoshop-compatibility
claim.

## Atomicity and results

- Every input and every sample is preflight/validated before any destination
  write. A late invalid input (e.g. affected NaN source, malformed mask, or
  non-finite computed result) leaves the entire destination range unchanged and
  returns `false` with `*changed` cleared when non-aliased.
- Valid calls with no raw-byte output change return `true` with
  `*changed == false`.
- Borrowed memory must remain stable for the duration of the call; no
  reentrancy or concurrency guarantees beyond that.

## Files

- `Engine/lab-fill.h` — private declaration and contract.
- `Engine/lab-fill.c` — implementation.
- `Engine/tests/lab-fill-tests.c` — literal/independent checks.
- `scripts/test-lab-fill.py` — builds and runs optimized and sanitized modes.
- `docs/lab-fill.md` — this note.
