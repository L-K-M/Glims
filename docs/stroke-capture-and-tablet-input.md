# Stroke capture facts and versioned tablet input

The additive API-v1 tail provides deterministic capture facts for supported
ordinary strokes, followed by versioned Begin and Continue entry points for
optional tablet coordinates. Existing V1 stroke layouts and calls stay intact.
This native foundation does not itself wire AppKit tablet events or the
Recorder interface.

## Capture facts

The ordinary capture entry point reports the brush's owned resource identity
and a SHA256 fingerprint before the first paint operation. Replay can provide
expected facts; a mismatch refuses before painting. Unsupported capture still
allows an otherwise valid ordinary stroke, with absent facts rather than an
invented deterministic result.

Supported tools are Pencil, Eraser and Paintbrush. Fingerprints cover the
complete supported brush mask, generated-brush recipe and consumed paint
configuration. Size-from-pressure dynamics additionally include their complete
native curve/configuration data; other dynamics outputs and unknown serialized
properties refuse facts. Bounded name/icon metadata and null pixbuf metadata
are allowed without treating metadata as brush pixels. Existing Pencil/Eraser
fingerprint bytes are preserved; Paintbrush has a separate appended domain.
Pixmap/pipe brushes, unsupported formats and unsafe paint contexts refuse
facts. There is no cross-engine pixel compatibility guarantee.

## V2 input contract

V2 uses an owned packet header and explicit sample size/stride, with no raw
GIMP types crossing the facade. The engine worker copies and validates a whole
packet before issuing any Core paint call. Limits are 4,096 samples and 1 MiB
of packet payload; known prefixes can be unaligned and larger strides can
carry ignored future tails. Invalid sizes, arithmetic, coordinates, ranges,
presence flags or absent-axis payloads refuse the whole request.

Only V2 applies the finite coordinate box of ±524,288 and modular UInt32
millisecond ordering. Equal times are permitted; forward deltas must be less
than half the UInt32 range. Rejected packets do not advance the accepted clock.
V1 retains its existing input behavior. A live stroke cannot mix V1 and V2
Continue calls.

Present rotation uses turns in [0, 1); tangential pressure uses [-1, 1].
Absent optional axes reset to fresh native defaults on each sample, including
rotation 0 and wheel 0.5. Begin captures the brush resource and input format.
Both versions share the existing End, native history and image-close cleanup.
No velocity/direction inference or visible wheel/rotation dynamics is added.

## Verification

Native source `28ae33c632b645059794a49dd4ce8623e366d176` passes:

| Suite | Checks across GIMP 3.2.8, 3.2.0, 3.0.8 and master |
| --- | ---: |
| General conformance | 7,454 |
| V2 packets and actual Core forwarding, 142 per engine | 568 |
| Pressure-size fingerprints, 100 per engine | 400 |
| Original capture-facts compatibility, 60 per engine | 240 |
| Default Paintbrush facts, 52 per engine | 208 |
| Total | 8,870 |

The V2 fixture records actual Core coordinates, IDs and times through private
test-only forwarding, with independent ordinary-paint pixel/Undo references.
It also covers invalid packet atomicity, clocks, format mismatch, resource
ownership and teardown. The old facade baseline executes its V1 controls and
fails the missing V2 tail. The Paintbrush and pressure baselines likewise
reproduce missing facts before their additions. Production diagnostics and
extra exported test symbols are not introduced.

The later Main integration at `c70d6fb` changes no native production file,
header or focused oracle from that producer; its only native test difference
is the separately reviewed Displace lifetime fixture. Frontend routing,
physical tablet calibration, high-rate event delivery and final combined
bundling remain separate validation work.
