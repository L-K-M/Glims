# Native CMYK documents

This integration adds New Image > CMYK with an explicit source ICC profile and
four authoritative Cyan, Magenta, Yellow and Black channels. It supports 8-bit,
16-bit and 32-bit float samples. It is a first native CMYK editing slice, not
complete Photoshop 4 parity or complete CMYK command support.

The component storage contract accepts mode 2 with exactly four planes. Each
plane retains its UUID and scalar intensity: zero is full ink, one is paper.
A persistent `glims/plate-profile` image parasite contains the exact source ICC
payload, limited to 4 MiB. Full validation occurs before creation/adoption;
each subsequent operation binds to the exact bytes captured at adoption.
Invalid metadata refuses rather than becoming an ordinary grayscale image.
A source profile cannot currently be replaced in place.

The preview owns a private LittleCMS transform, four referenced plane buffers
and a derived linear-sRGB RGBA buffer. It converts native full-resolution ink
values before constructing zoom mipmaps, using relative colorimetric intent
and black-point compensation. The normal display-profile conversion follows
once. Hidden channels supply paper intensity. Finite extended float samples
clip only in the derived preview; authoritative samples remain unchanged.
NaN/infinite source samples fail the render. A later retry invalidates failed
cache entries, so repairing data cannot expose a cached placeholder as valid.
Conversion scratch space is bounded to 256 pixels rather than the image area.

Brush, Pencil and Airbrush target one native ink plane, with selection coverage,
pressure and Undo inherited from component painting. Channels permit selection,
visibility and naming. Their color is defined by the ICC profile, so arbitrary
ink recoloring is disabled. XCF stores the original channels, UUIDs and ICC bytes.
Other commands remain subject to the explicit component-operation policy;
export, RGB conversion, layers, filters and profile reassignment are not enabled
by this slice. Existing RGB/Grayscale/Indexed and Multichannel behavior remains
separately tested.

## Verification in progress

All four adapters pass 181 public CMYK checks and 227 native storage/preview
checks, plus the existing 4,060 Multichannel, 171 storage and 216 command-admission
checks. Native checks use an
independent double-precision LittleCMS oracle, exact raw-plane comparisons,
Undo/Redo, nonzero-origin crops, full/half-scale previews, XCF identity, damaged
profiles and nonfinite-sample recovery. The installed system CMYK profile is
read in place and is not redistributed. These results are one-profile evidence,
not a claim for every press profile.

All 1,519 unit tests pass. The actual CMYK window workflow passes 177 checks on
each engine, covering all three precisions, profile selection, two ink targets,
responder Undo/Redo, channel attributes and XCF reopening. The pinned full editor
suite passes 3,352 checks. Independent source reviews of preview ownership/cache,
document admission/profile lifetime and UI integration found no confirmed
important findings. The remaining full-engine app matrix, standalone bundle
and latest CI qualification are still pending for this integration.

At 4096 × 3072 pixels with a 1024 × 768 viewport, shared-load measurements on
this Mac took 133–143 ms for the cold 100% viewport and 1.87–1.89 seconds for
the first 25% fit view. Warm and post-dab renders took 7.2–7.6 ms. Peak process
RSS was 764 MiB across three sequential precision cases. The fit read reuses
the earlier viewport cache; the source is mostly paper with a few pencil dabs.
These timings measure engine calls, not complete pointer-to-display latency.

Reproduce against a matching adapter producer, with a compatible external ICC:

```sh
GLIMS_ADAPTER_ROOT=/absolute/adapters scripts/build-adapter.sh --test GIMP_3_2_8
python3 scripts/test-cmyk-editor.py \
  --library /absolute/adapters/GIMP_3_2_8/libglimsengine.dylib \
  --cmyk-profile /absolute/source.icc
python3 scripts/test-cmyk-storage-preview.py \
  --producer /absolute/adapters/GIMP_3_2_8 \
  --cmyk-profile /absolute/source.icc
python3 scripts/test-component-perf.py \
  --library /absolute/adapters/GIMP_3_2_8/libglimsengine.dylib \
  --cmyk-profile /absolute/source.icc
```

Both fixtures isolate native settings and caches. Add `--work /absolute/logs`
to retain logs and generated files. The UI fixture is selected with
`GLIMS_SMOKE_CASE=cmyk` when running `Glims --engine-smoke-test` with a matching
engine library; run it under an owned desktop lease and release after exit.
