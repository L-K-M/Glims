# Recorder

Channel > To Selection records ordinary saved channels. Using the transient
Quick Mask channel keeps the live edit and adds an explicit failed recording
row; the log remains saveable, and replay refuses its incomplete sequence.

The Recorder palette shows the open image's recorded semantic commands in
acceptance order, with explicit Recorded, Failed or Cancelled text. Window >
Recorder opens it. Edit > Recorder and the palette expose the same commands.

Current capture covers these command families:

- Rectangle, ellipse and polygon selections, with their selection options.
- Color selection, with its point and options.
- Selection commands, including Select Alpha and radius-based changes.
- Channel ▸ To Selection, with its combination operation and the explicitly
  invoked source channel (which may differ from the active paint target).
- Image rotation and flipping.
- Image scaling.
- Canvas resizing, with offset and fill color.
- Image cropping.
- Supported layer property changes: name, visibility, opacity and blend mode.
- Complete Pencil, Eraser and Paintbrush gestures with supported brush settings.

Other layer changes, effects and file operations remain outside this
capture scope. A live recording belongs to one open image. To use a saved
recording in another image, load it in that image and choose its targets.

## Stroke capture

A stroke reserves one row when its owning document accepts the press. Its
copied tool settings, explicit pixel-layer binding and ordered samples stay
with that document even if another window becomes frontmost. Stop refuses
new rows but lets an accepted gesture finish. The row becomes successful only
after native End; a failed begin, sample batch or End leaves a failed row.
An unsupported recording never prevents otherwise valid live painting.

Replay resolves the recorded brush identity and checks its complete supported
fingerprint before starting a native stroke. The fingerprint includes the
brush mask and generated-brush recipe, consumed paint options and supported
size-from-pressure dynamics. A changed brush or configuration refuses replay
before painting. Supported dynamics have only the size output driven by
pressure; other outputs, pixmap/pipe brushes and unknown configurations refuse
capture. There is no promise of portable pixels across engine versions.

The trace stores image coordinates, pressure, signed tilt and millisecond
timestamps, with the accepted batch boundaries intact. It does not infer
velocity or direction. Only ordinary pixel layers can be bound for stroke
recording; painting a mask/channel or using another paint tool produces an
explicit unsupported row. Saved strokes use recording format version 2;
recordings without successful strokes retain version 1; Channel ▸ To Selection
raises the file to version 3. See
[the file format](recorder-file-format.md) for its closed schema and limits.

Record starts a fresh log, replacing the prior recording. Stop stops accepting
new recorded commands; accepted work still finishes and settles into its
original order. The pending count stays visible. The palette waits for pending
capture before offering Replay or a new recording. Clear removes the log
without editing the image. A failed or cancelled captured command prevents
replay of that log, so a partial success cannot masquerade as a complete macro.

Replay uses the image's current state. Color selection that samples a drawable
and Select Alpha retain their original layer/channel/mask and Quick Mask
context. Channel to Selection replays against its recorded source channel,
freshly validated in the native image before any mutation; it never falls back
to the active paint target. Changed or unavailable bindings refuse with a
reason. The driver
checks cached admission and fresh native targets, respects the live commands'
floating-selection policy, and refuses unsettled work, conflicting operations
or a closing image.

Each replayed command keeps its normal native Undo behavior. Replay does not
group the whole recording into one transaction, and a legitimate no-op need not
add an Undo entry. Failure stops later scheduling and displays the failed
command's one-based index and reason; earlier successful changes remain.
Cancel Replay also stops later scheduling. A command already accepted by the
engine may finish after cancellation; cancellation does not roll back changes.
Closing refuses new actions while accepted work and teardown drain.

## Naming, saving and loading

**Name Recording** changes the recording's title. It can differ from the
filename. Stop recording and let accepted commands finish before using
**Save Recording** or **Load Recording**.

**Save Recording** writes a `.glimsrecording` file with the command values,
outcomes and original target descriptions. It contains no image pixels or live
engine IDs. It uses a versioned JSON format with a 16 MiB limit. A save clears
the Recorder's unsaved mark only if it wrote the current recording revision.
The image's Save and Export commands remain separate.

**Load Recording** reads the file in the window that invoked it. When commands
use specific layers, masks or channels, choose each target in the binding
sheet. A matching name is a description; it does not select a target. Loading
installs the command list. Use **Replay** separately to edit the image.

Before replacing an unsaved recording or removing it through Close, Quit or
Revert, Glims offers Save, Discard Changes or Cancel. Discard Changes grants
permission for the pending action. Cancelling the next panel or image prompt
still leaves the recording in place. When you save from a Close or Revert
prompt, accepted work settles before the snapshot is written.

Recorder observers use removable document-owned tokens. Retargeting removes
only the palette's subscription, and stale callbacks cannot replace another
image's rows. The existing image-state, error and Recorder callbacks remain
owned by their original consumers.

## Verification and remaining work

These are distinct focused AppKit/native-state matrices on GIMP 3.2.8, 3.2.0,
3.0.8 and master:

| Scope | Source revision | Checks per engine |
|---|---|---:|
| Capture admission, immutable values, ordered settlement and close | `f03ef62` | 36 |
| Replay sequencing, target/floating policy, failures and cancellation | `6cae7bb` | 61 |
| Actual palette controls, menu routes, observers, retargeting and native results | `4e3189f` | 43 |

The capture matrix includes two leaked-buffer diagnostics on 3.0.8 and missing
cache-XML diagnostics on master; the separate source audit identifies older
upstream selection-buffer ownership and unsaved-cache cleanup paths. Those
diagnostics are not evidence of a clean resource audit and are not fixed here.

The persistence work adds explicit binding and detached Save checks. Earlier
pinned runs pass 51 installation, 24 save, 16 default Quick Mask color,
15 close-consent and 18 active-snapshot checks. Subsequent focused matrices
include actual Save/Load picker and consent workflows; these individual runs
do not establish a final combined release.

The combined native source at `28ae33c` passes 7,454 general conformance checks
across the four engines, plus 142 versioned-input, 100 pressure-fingerprint,
60 original capture-facts and 52 Paintbrush checks per engine: 8,870 total.
The 142 input checks exercise the native V2 packet API; they do not establish
frontend delivery of optional tablet axes or physical device calibration.

The integrated Recorder source at `8155565` passes 22 capture and 26 saved-file
checks per engine. Its actual Paintbrush canvas fixture passes 23 per engine,
including captured-document ownership, Stop before release, explicitly bound
replay, independently seeded native pixels and Undo/Redo. The preceding
Pencil/Eraser canvas, Revert and real application-Quit fixtures respectively
pass 23, 10 and 13 checks per engine. Each matrix uses temporary signed hosts
and immutable native adapters, with owned teardown and desktop release.
The latest-Main integration at `555792d` passes all 1,195 unit tests; its
independent file/consent source review found no important issue.

Hosted CI, final publication feedback and the final
self-contained bundle remain separate gates. Long failure text at the
three-line status limit still needs the final accessibility check; no clipping
defect has been reproduced. Broader semantic capture remains open.
