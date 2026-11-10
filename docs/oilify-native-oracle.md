# Direct native Oilify oracle

This opt-in fixture records GEGL's Oilify behavior and GIMP's direct drawable
filter behavior. It uses the existing adapter to open an isolated engine,
create images and read history. The graphs and native filter actions come from
the fixture. The four reference producers are the existing Displace builds for
GIMP 3.2.8, 3.2.0, 3.0.8 and master.

The raw graph uses finite linear RGBA floats over a 5 × 5 target. The center
has gray 0.875 and alpha 0.75, with four radius-one neighbors at gray 0.125 and
alpha 0.25. The four neighbors occupy one intensity bin, and the center
occupies another. With exponent eight, their bin weights are 1 and 1/65536.
The assertions allow an absolute float error of 0.000002 for the arithmetic
and format conversions.

| Input | Expected raw result |
| --- | --- |
| Both maps absent | The literal weighted center and alpha follow the two histogram bins. The extent matches the target. |
| Black radius map alone | Effective radius zero copies the center at every pixel in Intensity mode. |
| Black exponent map alone | Effective exponent zero gives equal bin weights, with center gray and alpha both 0.5. |
| Both maps with different extents | The native union is `(-1, -1, 8, 6)`. The white radius at the center and black exponent yield 0.5 there. The black radius at the corner keeps the corner sample. |
| Finite out-of-range maps | Radius luminance 1.25 matches the full radius. Exponent luminance −0.25 matches the zero exponent. |
| Fractional maps | Exponent 3.92 truncates to three. Radius 1.5 includes the four diagonals and excludes points at distance two. |
| One-pixel exponent map | The finite map extends its edge value over the chosen result rectangle. |
| Equal RGB and different map alpha | The straight RGBA inputs yield the same luminance-scaled result. |
| Radius zero in per-channel mode | The center quantizes to gray 6/7 and alpha 5/7 at eight intensities. |
| Upper scalar limits | Radius 100, exponent 20 and 256 intensities produce finite output on the small CPU case. |

The direct Core cases each use a 32 × 32 RGBA8 target at item offset `(3,4)`.
They exercise plain Oilify and the two-map graph with image selection
`(9,11)..(23,26)`. The map item offset and its buffer origin are measured
separately. Each preview must change pixels within that selection and keep the
stored bytes and history. Cancel restores the original rendered bytes. Apply
must change pixels within the selection, retain the layer extent and offset,
and add one Undo. Undo and Redo compare all target bytes. The log records
whether preview and merge bytes agree and whether native alpha changed.

Build and run are separate commands. Use a fresh directory for each build
and a separate fresh run directory. The driver reads existing response files
and links the fixture against the producer's objects. Run uses private home,
configuration, cache, data, temp and swap directories. The fixture disables
OpenCL for the raw and Core cases.

```sh
python3 -I scripts/test-oilify-native-oracle.py build \
  --producer /path/to/existing/displace169-adapters/GIMP_3_2_8 \
  --out /tmp/oilify-oracle-328-build
python3 -I scripts/test-oilify-native-oracle.py run \
  --binary /tmp/oilify-oracle-328-build/oilify-native-oracle-tests \
  --work /tmp/oilify-oracle-328-run
```

Retain the build's `inputs.json`, `inputs-after.json` and `binary.json` with
the run's `native.log`, `run.json` and `artifacts/`. On the complete path the
fixture predicts 73 checks and 28 pixel files. Raw frames are row-major native
float RGBA with 400 bytes per file. Core frames are row-major nonlinear RGBA8
with 4096 bytes per file. The run receipt hashes every captured frame. The
fixture logs operation extents, center samples, alpha and history facts, and
timing for the small raw cases. These are source expectations pending actual
execution on all four producers. Captured-map admission, immutable source
lifetime, precision refusal and budget tests belong to the later facade work.

## Projection and merge diagnostic

The four original `17d4543` runs each passed 73 checks. Their retained
drawable previews differ from raw Apply at 188 pixels for plain Oilify and
33 for the mapped case. The largest channel deltas are `(7,7,0,19)` and
`(1,1,0,19)` respectively. The mapped differences lie within two pixels of
the selection edge. These are drawable reads, so the actual image projection
needs a separate measurement.

Add `--diagnostics` to the run command and choose a new work directory. The
diagnostic runs after the original assertions. Each fresh 32 × 32 scene hides
the white background so the image projection exposes target alpha. It saves
raw and with-effects bytes in drawable-local coordinates and saves the
adapter's scale-one `image_render` projection as premultiplied RGBA in image
coordinates. Comparisons stay within one representation. The test records
changed pixel counts, per-channel maximum deltas and difference bounds.

GIMP's `gimp_drawable_filter_layer_mask_freeze` sets a mask property whose
setter can resync the graph after attachment. `gimp_drawable_filter_sync_region`
checks whether the filter is first in the stack when selecting its input
crop. The native merge also reads the applicator's valid cache rectangles,
then processes the remainder in the clipped rectangle. The diagnostic logs
the actual Oilify input producer and bounds, selection intersection, region,
clip request, frozen-mask presence, cache rectangles and format at the
attached, preview and pre-commit stages.

| Paired controls | What the observations decide |
| --- | --- |
| Late, early and omitted freeze with the same selection | A changed crop and fresh drawable bytes immediately after freeze establish a graph change before Apply. Early freeze can show whether the preview matches that graph. |
| Same region resynced after attachment, with a live unfrozen selection | Matching early-freeze pixels here implicates region resync independently of copying the mask. |
| Empty selection and selected drawable-region control | A result that depends on selection-region input bounds can be separated from the presence of a selection mask. |
| Cache disabled, selection-sized projection read first, and drawable-only pre-Apply reads | Cache metadata and same-stage bytes show whether those particular cache or read-rectangle changes affect the result. |
| Late-freeze probe with lazy projection, refreshed adapter projection and eager Core projection | The eager read uses the same image rectangle and premultiplied format after explicit invalidation. Differences here distinguish projection freshness or rendering from changes already present in fresh drawable bytes. |
| Mapped late and early freeze | The same timing comparison tests the source-mapped case. |

Only the late-freeze probe reads pixels between late freeze and Apply.
It records the refreshed projection separately because those reads can warm
the graph. The diagnostic predicts 187 setup, capture and lifecycle checks
and 112 extra frames. Pixel differences are observations. The original 73
assertions run first and keep their separate result count.
