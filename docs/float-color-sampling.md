# Native color sampling

The Color Picker and Option-click with a painting tool read the composited
image before display quantization or soft proofing. Sampling a float image
therefore retains native projection fractions instead of rounding them to
8-bit display bytes. Coordinates refer to one image pixel, inside the canvas.
The read does not change pixels, selection, profiles, dirty state or Undo.

API version 1 appends slot 174, `image_sample_color`. Its owned
`GlimsSampledColor` contains straight nonlinear sRGB doubles. Native projection
precision still applies. RGB can exceed 0–1 for wide-gamut or HDR sources;
alpha must be finite in 0–1. Public dispatch clears output and the optional
error pointer, including refusal and stopped-engine paths. Unknown images,
outside coordinates and missing output refuse; invalid native components
fail explicitly. The read uses the shared one-pixel projection validation,
then requests straight double components from GEGL. No display/profile-proof
transform, premultiplication, byte quantization or global color state is used.

The tool foreground remains an opaque, bounded sRGB editing color. It keeps
the sampled fractions within that range; extended RGB values are clipped
only when becoming that editing color, with an explicit status message.
Fully transparent samples choose black, preserving the previous tool policy.
The native image remains unchanged. This does not add HDR canvas presentation
or change the other color forms.

## Verification

The original actual-canvas regression failed two of eight checks: both the
Color Picker and Option-paint route quantized a 32-bit float source. The fixed
routes pass. The expanded fixture also assigns Display P3 after filling a
red source, requires a genuinely extended sample, checks the bounded editing
color and clipping message, and preserves native profile and Undo. All four
engines pass 12 checks each (48 total).

The independent native harness compares slot 174 with GimpPickable and
GeglColor references on the engine thread. It covers fractional float values,
partial alpha, grayscale/indexed/linear sources, generated wide-gamut ICC,
fresh one-pixel reads after mutation, state preservation, active-stroke reads,
refusal output/error clearing and actual nonfinite projection components.
All four supported engines pass 120 checks each (480 total), alongside 7,454
general conformance and 136 codec checks. Independent SWE-2 source review
found no important issue. Full unit, latest-head CI and final integrated
bundle verification remain pending at this checkpoint.

Build the adapter first into a private producer, then compile and run the
fixture separately (the driver refuses to overwrite evidence or its producer):

```sh
GLIMS_ADAPTER_ROOT="$PWD/.build/sample-adapters" scripts/build-adapter.sh --test GIMP_3_2_8
python3 scripts/test-sample-color.py build --ref GIMP_3_2_8 \
  --producer "$PWD/.build/sample-adapters/GIMP_3_2_8" --out "$PWD/.build/sample-fixture"
python3 scripts/test-sample-color.py run \
  --binary "$PWD/.build/sample-fixture/sample-color-tests" --work "$PWD/.build/sample-run"
```

The producer's objects and response files are hashed before and after linking.
The run uses a private home/cache/configuration and bounded execution. These
checks do not establish physical monitor accuracy or a standalone app bundle.
