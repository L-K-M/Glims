# Native display proof rendering (slot 164)

View > Soft Proof Setup selects an ICC simulation profile and independent
proof/display intents and black point compensation. View > Soft Proof toggles
the captured settings for that window. The image, working profile, history and
saved simulation metadata remain unchanged. The settings stay with the window;
they do not change another document or window.

`GlimsEngineAPI.image_render_proofed` appends one slot to API version 1. Its
arguments are image, scale/area, destination ICC bytes/length, proof ICC
bytes/length, a `const GlimsProofSettings *`, caller output/stride, and error.
The separate function always requests proofing. Existing slot 132's signature,
fixed relative-colorimetric/flags-zero policy, and unproofed behavior remain.

`GlimsProofSettings` contains four owned uint32 fields: `struct_size`,
`proof_intent`, `display_intent`, `flags`. Both intents use the existing
`GlimsProfileIntent`; Engine maps all four values explicitly to native
constants. The sole flag is `GLIMS_PROOF_BLACK_POINT_COMPENSATION = 1`.
NULL/short settings, invalid intents, unknown flags, NULL/empty or above 16 MiB
ICC blobs, and invalid render bounds/stride are refused before writing caller
output. Future settings tails are ignored. No native enum values or layouts
cross this facade.

The source is the image's effective native profile, including its builtin
fallback. Destination must be RGB. Proof is parsed without an RGB restriction;
its profile/intent combination must be accepted by the native constructor.
Malformed profiles and unsupported native transforms fail explicitly, without
falling back to unproofed or sRGB pixels.

The shared internal renderer keeps the existing projection-own-space straight
float read, bounded chunking and single-pixel freshness behavior. Proofing
uses `gimp_color_transform_new_proofing` with source/destination/proof profiles,
proof intent, display intent and mapped BPC flag. In the unproofed branch the
original `gimp_color_transform_new` call retains relative intent and flags 0.
The destination Babl space is always obtained with relative intent: it is
only used for same-space association/quantization after LCMS has applied the
selected intents. Babl does not implement saturation/absolute ICC intents;
passing those choices to this encoding-only lookup incorrectly refused
otherwise valid native proof transforms. The runtime tests exposed this
refusal before the lookup was corrected.
Transforms operate on straight components and preserve alpha; one final Babl
conversion premultiplies into destination-profile RGBA u8. Output must be
tagged with the same destination ICC bytes by the Swift renderer.

Both blobs are copied synchronously into owned native profiles and no caller
memory is retained. The source profile and projection buffer are borrowed
from the live image. Profiles/transforms/scratch are created, used and freed
within one synchronous engine-thread call. There are no image simulation
setters, nested loops or write-admission checks. Image pixels/profile,
selection, dirty/history and saved simulation state are not changed.

Native source: `_engine/src/<ref>/gimp/libgimpcolor/gimpcolortransform.h:67`
and `.c:309` for GIMP_3_2_8, GIMP_3_2_0, GIMP_3_0_8 and master. Their transform
headers/bodies are byte-identical across these four inspected trees. The
constructor itself adds native soft-proofing and alpha-copy flags; it does
not offer independent paper/black simulation controls. GTK/widget code is
reference only and is not linked.

The standalone `Engine/tests/proof-render-tests.c` calls the actual slot 164
and builds an independent native transform over independently read source
pixels. It generates a mandatory discriminating RGB ICC, compares all 32
intent/BPC combinations with explicit alpha/premultiply/stride oracles, tests
Gray proof acceptance against the native constructor, malformed/invalid
requests, future settings tails, busy-read admission and native state
preservation. Two additional fresh images are actually converted to grayscale
and indexed, then compared against native own-space Y'A-float/RGBA-float
projection references with read-only state checks. The mandatory RGB
discriminator must fail if the fixture happens
to produce unproofed-equivalent output; it is not silently skipped.

`scripts/test-proof-render.py build --producer PREFIX --out DIRECTORY`
compiles/links only, replacing the existing producer display-render.o once.
The producer must already contain fresh API164 engine.o; no producer is
rebuilt or overwritten. `run --binary BINARY --work EMPTY_DIRECTORY` is a
separate explicit action with private HOME/XDG/GIMP/TMP. Optional
`--cmyk-profile PATH` reads an external CMYK profile in place, adds a counted
native-reference matrix, and never copies/redistributes that profile. The
local system Generic CMYK Profile may be supplied for local tests only.

Existing slot 132 tests remain unchanged. Current native conformance passes
1,917 checks on GIMP 3.2.8, 3.2.0 and master, and 1,703 on 3.0.8. The focused
proof harness passes 291 checks on each engine with the local CMYK fixture.
The initial display-intent lookup defect was observed as 96 failures before
the encoding-only Babl lookup was corrected.

## Window and form ownership

The canvas captures immutable proof bytes/options and the owning window's
destination per queued tile. A proof or destination change clears completed
and failed tiles and advances its generation. Late old-proof tiles cannot
repopulate the new cache. A requested proof never falls back to ordinary
unproofed pixels; an unusable profile or transform reports a draw error.
A missing window destination uses explicitly tagged sRGB as the destination
of the same native proof transform.

The setup form captures its document/window. ICC files are opened off-main
through a regular-file descriptor and read in bounded chunks, including if
the file grows. These reads and the native 1 × 1 preflight count as document
work and run behind accepted input, so close drains them. Successful Apply
captures bytes rather than retaining a path; later option edits can reuse
the profile after the original file has gone. Failures keep the draft and
the existing view. Cancel/close invalidate generation-fenced replies and
close the form's child file picker.

The actual UI case passes 23 checks on every supported engine, including the
optional local CMYK profile. Its mandatory generated-gray simulation changes
real colored/partial-alpha pixels, differs from unproofed rendering and
matches native proof output. It covers independent destination ICC tags,
held-render generation rejection, malformed/oversized file errors, retained
profile reuse, counted read Cancel and close. The full 988 unit suite passes.
The integrated release, CI and final review are tracked with the integration
candidate. Physical monitor/printer accuracy, HDR and
independent gamut/paper-white/black-simulation controls remain unverified or
unimplemented; they are not implied by this ICC simulation seam.
