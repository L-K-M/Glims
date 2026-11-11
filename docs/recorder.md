# Recorder

The Recorder palette shows the open image's recorded semantic commands in
acceptance order, with explicit Recorded, Failed or Cancelled text. Window >
Recorder opens it. Edit > Recorder and the palette expose the same commands.

Current capture covers these command families:

- Rectangle, ellipse and polygon selections, with their selection options.
- Color selection, with its point and options.
- Selection commands, including Select Alpha and radius-based changes.
- Image rotation and flipping.
- Image scaling.
- Canvas resizing, with offset and fill color.
- Image cropping.
- Supported layer property changes: name, visibility, opacity and blend mode.

Strokes, other layer changes, effects and file operations remain outside this
capture scope. A live recording belongs to one open image. To use a saved
recording in another image, load it in that image and choose its targets.

Record starts a fresh log, replacing the prior recording. Stop stops accepting
new recorded commands; accepted work still finishes and settles into its
original order. The pending count stays visible. The palette waits for pending
capture before offering Replay or a new recording. Clear removes the log
without editing the image. A failed or cancelled captured command prevents
replay of that log, so a partial success cannot masquerade as a complete macro.

Replay uses the image's current state. Color selection that samples a drawable
and Select Alpha retain their original layer/channel/mask and Quick Mask
context. Changed or unavailable bindings refuse with a reason. The driver
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

The persistence candidate adds explicit binding and detached Save checks.
The pinned 3.2.8 runs pass 51 installation, 24 save, 16 default Quick Mask
color, 15 close-consent and 18 active-snapshot checks. The separate native
picker acceptance, remaining engine runs and integrated bundle checks
remain pending. Long failure text at the three-line status limit still
needs the final accessibility check; no clipping defect has been reproduced.
Broader semantic capture remains open.
