# Optional tablet coordinates

Painting captures the input format at the accepted press. A tablet-point
press uses V2 only when its device matches a cached real proximity event
advertising rotation or tangential pressure through the named IOKit capability
masks. Ordinary mouse input, missing proximity and tablets without those
capabilities retain V1, including ordinary Recorder capture facts. No live
gesture changes format or falls back after a V2 refusal.

The gesture owns its document, copied brush and press-time device/capabilities.
Later matching samples provide only the axes captured at press. Wrong-device
or ordinary mouse samples reset optional axes to absent within the same V2
format. Proximity leave and app deactivation affect future captures; they
cannot change the owned press snapshot. The passive monitor returns original
events and does not paint standalone proximity or tablet-point events.

Rotation is normalized from finite degrees into turns in [0,1). Signed
tangential pressure passes through the owned facade and maps to native wheel
as `(value + 1) / 2`. Missing optional axes reset native rotation to 0 and
wheel to 0.5. Base pressure/tilt and view-to-image coordinates keep their
existing semantics. Event kinds are checked before tablet-only getters.

Timestamps reject negative/nonfinite values and overflow before conversion;
checked floor/modulo yields UInt32 milliseconds without an intermediate Int.
V2 additionally validates its finite coordinate and axis ranges. Invalid down
admits nothing, invalid drag submits nothing, and an invalid release still
Ends accepted work exactly once. Begin, Continue and shared End retain the
document's counted input queue and End-before-close ordering.

Recorder's portable V2 file format currently stores complete V1 base traces.
A successful live V2 tablet begin therefore reserves and settles an explicit
unsupported row: rotation and tangential pressure are not saved. Live painting
continues; Stop waits for End. Native begin failures retain their actual error.
No partial successful trace or conversion to V1 is invented.

## Verification

The admitted old-frontend baseline at `4b0f4e0` executes22 checks with exactly
one missing-optional-coordinate failure. Its native reference pixels, Undo,
actual NSEvent readback and V1 control groups all pass.

Reviewed production `e568f9f` keeps the original22 predicates and passes their
optional-coordinate case. Its appended invalid-coordinate setup initially
fails because changing a copied CGEvent's global location does not change the
retained window-local position. Test-only `5865af3` constructs that local
position before applying the unchanged tablet fields. Actual readback then
confirms image coordinate `(600000,16)`, beyond the V2 limit, for both press
and release; the rejection predicates remain unchanged.

Latest-Main integration `4129720` passes32 actual pinned-engine checks and
41 real-Core telemetry rows, including Stop/End, immutable capability capture,
invalid press/release, one native Undo, an unsupported V2 recording and a
subsequent successful ordinary-mouse recording. All1,205 combined unit tests
pass. Independent source review finds no important issue in the six production
files, whose bytes are unchanged by the later fixture/Main integration.
Fresh all-four-engine focused runs and hosted CI remain publication gates.

The private adapter forwards to authentic Core paint calls and exports only
the ordinary facade entry. Telemetry is bounded to1,024 rows/1MiB in an owned
regular file; no diagnostics are added to production painting. Submitted CG
values and measured NSEvent quantization have separate literal expectations.
The fixture compares actual target IDs, ordered times, optional coordinates,
independent ordinary-stroke raw/composite pixels and Undo, then checks owned
teardown. The native142 packet matrix is separate evidence, documented in
[the native boundary](stroke-capture-and-tablet-input.md).

These synthetic events do not establish physical rotation direction/zero,
tangential calibration, high-rate event loss, every device or visible optional
brush dynamics. Global event coalescing is unchanged. Physical input and the
final standalone app remain separate checks.
