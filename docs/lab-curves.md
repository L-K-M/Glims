# Lab curves row

`Engine/lab-curves.{h,c}` provides `glims_lab_curves_row`, a bounded pure-C11
helper applying private normalized lookup curves for one PHYSICAL Lab row.
This does not enable Lab Curves as an app feature.

## API

```c
typedef struct {
  double samples[256];
} GlimsLabCurve;

bool glims_lab_curves_row(GlimsLabRole role,
                          GlimsLabFormat format,
                          const GlimsLabCurve *curve,
                          size_t count,
                          const void *source,
                          const float *mask,
                          void *destination,
                          bool *changed);
```

- `count <= 4096`, no heap allocation, no I/O.
- Source/destination/mask/curve/changed may be unaligned. Exact in-place allowed for source/destination.
- All other overlaps among source,dest,mask,curve,changed refuse before writes (checked uintptr range logic similar to lab-fill).
- `count == 0` permits NULL source/dest/mask but requires valid role/format/curve/changed.
- Full staging/validation makes late failure atomic. `changed` is false on errors unless it overlaps protected input/output. Invalid format/count has no accepted sample range; exact aliases and any settings overlap remain protected.
- Settings table always exactly 256 finite normalized `[0,1]` values; independent of role. Canonical identity is exact `sample[i]==(double)i/255`.
- Validate all settings/masks even no-op. Mask `NULL==full`; finite unit masks only in `[0,1]`.

## Processing

- Decode to physical double via unchanged `lab-samples`. Reject nonfinite affected float even identity.
- `coverage==0` copies raw bytes (including NaN/Inf/-0).
- Identity preserves every finite raw encoding including extended float/-0.
- Nonidentity integer source: lookup position is raw U8 code or U16 quotient/257 + remainder/257, avoiding early U8 quantization.
- Float input position normalized by L/100 or `(a_or_b+128)/255`; out-of-nominal inputs use endpoint samples.
- Linear interpolation rounds subtraction, multiplication and addition separately in double; exact U8 table indexing; U16 fraction = remainder/257.
- Map normalized output to physical with `fma(scale,lookup,offset)` where L scale 100 offset 0, a/b scale 255 offset -128. No artificial native ink/full-ink orientation.
- If mapped physical target == decoded source preserve original bytes.
- Blend physical output using same explicit lab-fill rule `fma(weight,target,(1-weight)*source)`, full weight exact target, repair roundoff to convex interval endpoints, then existing lab-samples encoding ONCE.
- Float must remain finite/in FLT_MAX. No gamut clipping.
- Represented-double arithmetic, not exact rational/Photoshop spline equivalence.
- Nonidentity float out-of-range maps endpoints; identity preserves them.

## Files

- `Engine/lab-curves.h` — private declaration and contract.
- `Engine/lab-curves.c` — implementation.
- `Engine/tests/lab-curves-tests.c` — independent literal/derived checks.
- `scripts/test-lab-curves.py` — builds and runs optimized and sanitized modes.
- `docs/lab-curves.md` — this note.

## Validation

Run `python3 -I scripts/test-lab-curves.py` for optimized and ASan/UBSan
checks. The optimized run also compiles a private shared library and compares
10,368 outputs with `scripts/test-lab-curves-oracle.py`, which uses Fraction
arithmetic for fused products and final quantization. It does not use the
production codec to compute expected values. C checks cover every U8 and U16
identity encoding on each axis, fractional masks, float payload preservation,
unaligned settings, overlaps, malformed settings and atomic late failures.

Parent regressions reproduced input corruption on invalid settings and an
unaligned-access sanitizer failure in the initial helper implementation. Both
are fixed. This remains a private numerical foundation: native image
transactions, preview, application controls and Recorder support are separate
work, and Photoshop equivalence is not claimed.
