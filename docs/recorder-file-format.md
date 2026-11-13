# Recorder file format, versions 1 to 15

The pure codec produces and reads detached values for named `.glimsrecording`
files. It performs no file I/O and holds no session state; file storage and the
recorder interface are implemented outside the codec. A successful decode does
not authorize execution or establish ownership of any open image.

The UTF-8 JSON envelope has exactly `format`, `version`, `recordingID`, `name`,
`origin`, `symbols` and `records`. `format` is `ch.lkmc.Glims.recording` and
`version` is integer `1`, `2`, `3`, `4`, `5`, `6`, `7`, `8`, `9`, `10`, `11`, `12`, `13`, `14` or `15`. `recordingID` is a file UUID. `origin` contains
`imageLabel`, `initialWidth` and `initialHeight`; these are descriptive hints.
Neither the label nor dimensions prove that a reopened image is the original.

The writer chooses the highest version required by a successful record:
`completeStroke` requires 2, `channelToSelection` 3, `transformLayer` 4,
`applyLevels` 5, `transformProjectiveLayer` 6, `applyCurves` 7,
`applyColorBalance` 8, `applyHueSaturation` 9, `applyBrightnessContrast` 10, `editInk` or
`applyInkLevels` 11, `applyInkCurves` 12, `fillLab`/`applyLabCurves` 13,
`completeLabStroke` 14, and `labSelectionShape`/`labSelectCommand` 15. A file declaring one of those versions must contain at least one
successful command from that version's family. It may also contain
commands from all earlier versions. Failure/cancelled rows do not raise
the version. With no extended successful commands, the writer uses
version 1. Integers outside 1...15 refuse the file.

Each symbol has an `id` UUID and `description`: `name`, owned `kind`, ordered
`ancestors`, `siblingIndex` and `bounds`. Ancestors contain `name`, group `kind`
and `siblingIndex`. Bounds are `{x,y,width,height}` numbers. Names and ancestry
are the immutable capture-time observations, not fresh export-time lookups.
Duplicate names are valid; duplicate symbol UUIDs are not. Symbols are logical
file references, never native IDs, persistent native tattoos or Recorder epochs.

Records remain in acceptance order with contiguous integer `ordinal` values
starting at zero. A `success` outcome has exactly `ordinal`, `outcome`, `command`
and `binding`. A `failure` or `cancelled` outcome instead has `reason`, including
an empty reason. The codec preserves every settled row. Failed/cancelled rows
do not contain an invented attempted command; the current log discards that
payload. Their presence continues to prevent replay in the log model.

Snapshot export refuses active recording, active replay and unresolved work.
Stop alone does not settle pending work. No partial successful prefix or pending
row is saved. There is no crash-journal interpretation of unconfirmed work.

## Commands and bindings

Commands have an owned `tag` and the following exact fields:

| Tag | Fields |
| --- | --- |
| `selectionShape` | `shape`, `options` |
| `selectColor` | `point`, `options` |
| `selectCommand` | `command`, `radius` |
| `channelToSelection` | `operation` (version 3 and later) |
| `transformImage` | `transform` |
| `transformLayer` | `matrix`, `interpolation` (version 4 and later) |
| `transformProjectiveLayer` | `matrix`, `interpolation` (version 6 and later) |
| `applyLevels` | `settings` (version 5 and later) |
| `applyCurves` | `settings` (version 7) |
| `applyColorBalance` | `settings` (version 8) |
| `applyHueSaturation` | `settings` (version 9) |
| `applyBrightnessContrast` | `settings` (version 10) |
| `editInk` | `operation`, `intensity`, `opacity` (version 11) |
| `applyInkLevels` | `lowInput`, `highInput`, `gamma`, `lowOutput`, `highOutput`, `clampInput`, `clampOutput` (version 11) |
| `applyInkCurves` | `samples` (version 12) |
| `scale` | integer `width`, `height` |
| `resizeCanvas` | integer `width`, `height`, `offset`, `fill` |
| `crop` | `rect` |
| `layerProperties` | `properties` |
| `completeStroke` | `settings`, `facts`, `first`, `batches` (version 2 and later) |

Shape tags are `rectangle`/`ellipse` with `rect`, or `polygon` with ordered
`points`. Points are `{x,y}`; rectangles retain `{x,y,width,height}`. Options
always contain `operation`, `antialias`, `feather`, `cornerRadius`, `threshold`,
`contiguous` and `sampleMerged`. Operations are `replace/add/subtract/intersect`.
Selection commands are `all/none/invert/feather/grow/shrink/border/sharpen/fromAlpha`.
Transforms are `rotate90/rotate180/rotate270/flipHorizontal/flipVertical`.

Layer `properties` can omit any of `name`, `visible`, `opacity`, `mode`; omitted
means unchanged. Explicit empty name, false visibility and zero opacity remain
distinct. An empty properties object is a valid no-op intent. Null never means
unchanged. Mode is a Glims-owned string tag, not a native enum number.

Colors contain exactly `space:"srgb"`, `red`, `green`, `blue`, `alpha`: finite
components inside 0...1. Canvas colors are the values actually passed by the
worker to native resize. No NSColor or late conversion enters the file.

Bindings are `kind:"none"`, `kind:"layer"` with `symbol`, `kind:"channel"`
with `symbol`, or `kind:"context"` with `context`. Layer properties, layer
transforms, Levels, Curves, Color Balance, Hue/Saturation and
Brightness/Contrast require a layer symbol (any layer-kind description);
`channelToSelection` requires a channel symbol whose description kind is
`channel` — the explicit source channel, never the active paint target.
Select Alpha and color selection with `sampleMerged:false` require context;
other non-ink commands require none. Native ink commands require the `ink`
binding below. Context has ordered `layers`/`channels` UUID
arrays, `target`, `masks` and
`quickMask`. Target kinds are layer/channel/quickMask with `symbol`, or mask with
`owner`. Mask entries contain `owner`, `isPresent`, `enabled`, `editing`,
`showing`; their owners match the layer set. Quick Mask has `enabled`,
`inverted`, `color`, and a `symbol` only while enabled. Role/primary ordering
and descriptor kinds must agree. Native IDs and channel/mask handles never appear.

The snapshot bridge uses only required successful-row symbols; failed rows do
not force reconstruction of discarded targets. Missing/unavailable required
capture-time descriptions refuse the whole export. Target-free legacy values
need no manufactured descriptor. Explicit unavailable bindings are refused.
Decoding produces descriptions for later explicit user binding; it never maps
names, tree positions or the current layer to a native target. Fresh ownership,
operation capability and current-image argument checks remain replay duties.

## Channel selections (version 3)

`channelToSelection` is the version 3 command. It records Channel ▸ To Selection:
the command carries only the combination `operation`
(`replace/add/subtract/intersect`), and the record's `channel` binding names
the explicit source channel symbol. The source channel is the one the live
action was invoked with; it may differ from the active paint target, which is
never substituted, and its symbol description must have kind `channel`. The
command is refused in a version 1 or 2 file, and a version 3 file without a
successful `channelToSelection` is refused, exactly as version 2 always
required a complete stroke.

## Layer transforms (version 4)

`transformLayer` is the version 4 command. It records one committed
Transform-tool affine: `matrix` has exactly the six coefficients `a`, `b`,
`c`, `d`, `tx`, `ty` as finite numbers, and `interpolation` is a Glims-owned
tag (`none/linear/cubic/noHalo/loHalo`), not a native enum ordinal. The
matrix acts in absolute image pixels, y down, on the explicitly bound layer;
it is never normalized to or adapted for a differently sized rebound layer.
The record's `layer` binding names the explicit transformed layer symbol,
never the implicit paint target or selection.

Every coefficient must be finite, the affine determinant `a*d - b*c` must be
finite with absolute value at least 1e-9 (matching the native degeneracy
bound; finite coefficients can still overflow it), and the identity matrix is
refused because live admission never admits it. The command is refused in a
version 1, 2 or 3 file, and a version 4 file without a successful
`transformLayer` is refused, exactly as earlier extensions always required
their own successful command. Fresh membership, lock and target-role gates and output
geometry against the bound layer's current native bounds remain replay
duties; the codec cannot prove a binding-time target. Live acceptance and
replay both require finite transformed corners within ±1,048,576 pixels and
outward-rounded output dimensions from 1 to 524,288 pixels. This check runs
before native mutation; symbol-description bounds cannot substitute for the
freshly bound layer's geometry.

## Projective layer transforms (version 6)

`transformProjectiveLayer` stores the exact nine finite row-major coefficients
`h00`, `h01`, `h02`, `h10`, `h11`, `h12`, `h20`, `h21`, `h22` and the same
owned interpolation tag as an affine. It maps column vectors `[x,y,1]` in
absolute image pixels, with y down; divide the first two outputs by the
third. No native runtime identity is serialized. The binding must name an
explicit layer symbol. Rebinding never adapts the matrix to the new size.

The codec refuses zero, singular and scalar-identity matrices. It checks
source-independent nonsingularity after magnitude normalization but preserves
the original coefficients in storage. Nonzero positive/negative scalar
multiples and `h22 == 0` can be valid. Horizon and output-geometry checks
require the actual bound layer rectangle, not descriptive symbol bounds,
and therefore run freshly before replay. Native allocation policy also
remains authoritative.

Both affine and projective semantic replay now call the captured native
transform API, which checks that the freshly read rectangle still matches
at mutation and refuses to implicitly rasterize editable text/link/vector
sources or descendants. Existing version 4 wire values are unchanged.

## Curves (version 7)

`applyCurves` has exactly `settings`, with `trc` and the five named channels
`value`, `red`, `green`, `blue`, `alpha`. `trc` is `linear`, `nonlinear` or
`perceptual`. Each channel has exactly `kind` (`smooth` or `free`), Boolean
`identity`, `points` and `samples`. Each point has finite `x` and `y` in 0...1
and `kind` (`smooth` or `corner`). Points are ordered by nondecreasing x;
zero points and duplicate x values are allowed. Each channel has at most
65,536 points. Points also consume the shared whole-file 100,000-point
budget. Samples are exactly 256 finite numbers in 0...1 per channel.

Both points and actual sample tables are stored, including inactive points
and imported Smooth tables that differ from what those points would derive.
The identity flag is the native HDR bypass behavior, never inferred from
points or samples. Replay installs a complete independent native candidate;
replaying graph-edit patches would lose some of this state. No native filter
or effect identity is serialized. A layer binding is required. Version 7
requires a successful Curves command and accepts all earlier command families.

Apply records final settings behind queued preview writes. Cancel adds no
row. An accepted commit that later fails settles a failure row while retaining
its capture metadata for retry. Mask/channel targets and existing-effect edits
produce explicit unsupported rows instead of inventing layer actions. Replay
checks current membership, color mode, locks and editing role, then commits
one new effect with one Undo step. This format preserves exact Curves values;
it does not change the native XCF format's handling of identity flags.

## Color Balance (version 8)

`applyColorBalance` is the version 8 command. It records one committed newly
applied Color Balance adjustment on the explicitly bound layer, exactly as
accepted by the live preview's Apply. `settings` has exactly `shadows`,
`midtones`, `highlights` and `preserveLuminosity`. Each tonal range has
exactly `cyanRed`, `magentaGreen` and `yellowBlue`; `preserveLuminosity` is
a Boolean. The whole accepted settings are stored by reading the open native
preview immediately before commit; visible panel fields, range selection or
a read after commit never substitute.

Every correction must be finite and inside −1...1, matching the typed native
settings contract; the closed bounds stay valid. The record's `layer`
binding names the explicit target layer symbol, never the implicit paint
target or selection; the command always requires one. Live filter, effect
and native layer IDs are never serialized. The command is refused in a
version 1 through 7 file, and a version 8 file without a successful
`applyColorBalance` is refused, exactly as earlier extensions always
required their own successful command. Fresh image/layer membership, mode,
lock, channel, Quick Mask, mask-editing and floating-selection gates against
the freshly bound layer remain replay duties; the codec cannot prove a
binding-time target.

Apply records final settings behind queued preview writes. Cancel adds no
row. An accepted commit that later fails settles a failure row while
retaining its capture metadata for retry. Mask/channel targets and
existing-effect edits produce explicit unsupported rows instead of inventing
layer actions. Replay checks current membership, color mode, locks and
editing role, then commits one new effect with one Undo step.

## Hue/Saturation (version 9)

`applyHueSaturation` is the version 9 command. It records one committed
newly applied Hue/Saturation adjustment on the explicitly bound layer,
exactly as accepted by the live preview's Apply. `settings` has exactly
`overlap` plus the seven named ranges `master`, `red`, `yellow`, `green`,
`cyan`, `blue` and `magenta`. Each range has exactly `hue`, `saturation`
and `lightness`; `overlap` is a number. The whole accepted settings are
stored by reading the open native preview immediately before commit;
visible panel fields, range selection or a read after commit never
substitute.

Every correction must be finite and inside −1...1, matching the typed
native settings contract; overlap must be finite and inside 0...1. The
closed bounds stay valid. The record's `layer` binding names the explicit
target layer symbol, never the implicit paint target or selection; the
command always requires one. Live filter, effect and native layer IDs are
never serialized. The command is refused in a version 1 through 8 file,
and a version 9 file without a successful `applyHueSaturation` is refused,
exactly as earlier extensions always required their own successful
command. Fresh image/layer membership, mode, lock, channel, Quick Mask,
mask-editing and floating-selection gates against the freshly bound layer
remain replay duties; the codec cannot prove a binding-time target.

Apply records final settings behind queued preview writes. Cancel adds no
row. An accepted commit that later fails settles a failure row while
retaining its capture metadata for retry. Mask/channel targets and
existing-effect edits produce explicit unsupported rows instead of
inventing layer actions. Replay checks current membership, color mode,
locks and editing role, then commits one new effect with one Undo step.


## Brightness/Contrast (version 10)

`applyBrightnessContrast` is the version 10 command. It records one
committed newly applied Brightness/Contrast adjustment on the explicitly
bound layer, exactly as accepted by the live preview's Apply. `settings`
has exactly `brightness` and `contrast`. The whole accepted settings are
stored by reading the open native preview immediately before commit;
visible panel fields or a read after commit never substitute.

Every correction must be finite and inside −1...1, matching the typed
native settings contract. The record's `layer` binding names the explicit
target layer symbol, never the implicit paint target or selection; the
command always requires one. Live filter, effect and native layer IDs are
never serialized. The command is refused in a version 1 through 9 file, and
a version 10 file without a successful `applyBrightnessContrast` is
refused, exactly as earlier extensions always required their own successful
command. Fresh image/layer membership, mode, lock, channel, Quick Mask,
mask-editing and floating-selection gates against the freshly bound layer
remain replay duties; the codec cannot prove a binding-time target.

Apply records final settings behind queued preview writes. Cancel adds no
row. An accepted commit that later fails settles a failure row while
retaining its capture metadata for retry. Mask/channel targets and
existing-effect edits produce explicit unsupported rows instead of
inventing layer actions. Replay checks current membership, color mode,
locks and editing role, then commits one new effect with one Undo step.

## Native ink commands (versions 11 and 12)

`editInk` stores one of `fill`, `clear` or `invert` and finite intensity/opacity
in 0...1; Clear and Invert use canonical values. `applyInkLevels` stores its
flat numeric endpoints (0...1), gamma (0.1...10) and Boolean clamps. Reversed
or equal endpoints are valid. These successful command families require v11.

`applyInkCurves` has exactly `tag` and `samples`; the array contains exactly
256 finite numbers in 0...1. There is no nested `settings` object, control-point
payload or native channel ID. The array is an owned copy of the accepted
Apply table. A successful ink Curves command requires v12; a declared v12 file
without one refuses. Earlier versions reject this tag. Failed/cancelled rows
never raise the selected version; previous command/version contracts remain.

All three require `kind:"ink"` with exactly `symbol`, `mode`, `role` and `uuid`.
The symbol describes a channel. Mode/role and the document-scoped plane UUID
must be valid and consistent for each symbol. See
[Recording native ink edits](ink-recorder.md) for explicit destination choices,
mode/role matching, fresh native admission and sole-selected-ink requirements.
The file UUID does not confer permission over another open document. Batch
name/path matching cannot automatically bind these ink commands.

## Levels (version 5)

`applyLevels` is the version 5 command. It records one committed newly
applied Levels adjustment on the explicitly bound layer, exactly as
accepted by the live preview's Apply. `settings` has exactly `trc`,
`clampInput`, `clampOutput` and the five named channels `value`, `red`,
`green`, `blue`, `alpha`. `trc` is a Glims-owned tag
(`linear`/`nonlinear`/`perceptual`), not a native enum ordinal, and both
clamps are Booleans. Every channel has exactly `lowInput`, `highInput`,
`gamma`, `lowOutput` and `highOutput`. The whole accepted settings are stored
by reading the open native preview immediately before commit; form defaults
or a read after commit never substitute.

Every endpoint field must be finite and inside 0...1, and `gamma` must be
finite and inside 0.1...10, matching the typed native settings contract.
Equal or inverted endpoints remain valid native mappings and round-trip
unchanged. The record's `layer` binding names the explicit target layer
symbol, never the implicit paint target or selection; the command always
requires one. Live filter, effect and native layer IDs are never serialized.
The command is refused in a version 1, 2, 3 or 4 file, and a version 5 file
without a successful `applyLevels` is refused, exactly as earlier extensions
always required their own successful command. Fresh image/layer membership,
mode, lock, channel, Quick Mask, mask-editing and floating-selection gates
against the freshly bound layer remain replay duties; the codec cannot prove
a binding-time target.

## Complete strokes (version 2)

`completeStroke` is the version 2 command. It serializes one whole accepted
gesture: brush settings, the engine's capture-time facts, the first sample and
the retained native batch boundaries. It carries no session ID or event object.
It is refused in a version 1 file. Like every successful record it carries a
`binding`; a complete stroke requires a layer symbol whose description kind is
`pixel`.

`settings` has required `tool`, `size`, `opacity`, `red`, `green`, `blue`,
`pressureSize` and `antiErase`, plus optional `hardness`.

- `tool` is exactly one of `pencil`, `eraser`, `paintbrush`: the lowercase
  Swift enum raw values on the wire.
- `size` is greater than 0 and at most 10,000.
- `opacity`, `red`, `green` and `blue` are inside 0...1.
- `hardness`, when present, is inside 0...1.
- `pressureSize` and `antiErase` are Booleans. `antiErase` may be true only for
  `eraser`; pencil and paintbrush require false.

`facts` has `brush` and `fingerprint`. `brush` is the capture-time identity:
required `name` and `isInternal`, optional `collection`. Names and collections
are native-bound strings, so NUL is refused, and `name` must not be empty.
`fingerprint` is exactly 64 lowercase hexadecimal characters (`0`-`9`, `a`-`f`).
The codec validates the stored shape; it does not recompute or freshness-check
the identity or fingerprint.

`first` is one stroke sample. `batches` is an array of non-empty arrays of
stroke samples. Batch boundaries are retained from accepted native calls, not
reconstructed pointer history. Every sample has required `x`, `y`, `pressure`,
`xTilt`, `yTilt` and `timeMilliseconds`:

- `x` and `y` are inside -524288...524288.
- `pressure` is inside 0...1.
- `xTilt` and `yTilt` are inside -1...1.
- `timeMilliseconds` is an integer in 0...4294967295.

A stroke's total sample count, `first` included, is at most 65,536 and counts
against the shared point budget below.

## Strictness and resource policy

Every object rejects unknown or missing fields. Duplicate decoded keys,
including escaped aliases, are rejected at any nesting depth. The parser rejects
invalid UTF-8, malformed escapes, unpaired surrogates, unescaped controls,
trailing data, invalid JSON number grammar, nonfinite overflow and nonzero
underflow to zero. Text values retain Unicode spelling without normalization.
Native-bound names additionally reject NUL. Integer fields accept integer tokens
only, with no decimal point/exponent; Boolean is never a number. Double fields
use finite IEEE binary64 values with normal nearest representation.

The limits below are **file-format resource policy**, not engine/hardware limits:

- 16 MiB UTF-8 input/output, 10,000 records and 10,000 symbols.
- 100,000 points summed across successful Curves channel points, polygon vertices and successful
  stroke samples (`first` included); each stroke is additionally capped at
  65,536 samples. Only successful records consume the budget.
- 64 KiB decoded UTF-8 bytes per string, including keys.
- JSON depth 64, one million JSON values, 128 bytes per number token.

No clipping or normalization occurs. Off-canvas coordinates, negative offsets,
fractional geometry and genuine zero values remain. Known native conversion
steps are checked: shape corner floor/ceil and integer spans; color-pick floor;
crop rounding; canvas offset truncation; selection-command rounded radius.
Snapped selection and rounded crop sizes must be positive, as their native
calls require; a zero source size at fractional selection corners can still
produce one snapped pixel. Only feather/grow/shrink/border require positive
radius; the other selection commands retain zero or unused negative radius.
Polygon coordinates remain doubles, as in the current native service. Scale
and canvas dimensions retain their current native 1...524288 domain. Native
selection/opacity clamping is not performed by this codec, so original finite
threshold/feather/opacity inputs retain their intent. Binding-dependent geometry
and native execution success cannot be established by a pure file decoder.

The codec owns the 59 layer/group mode tags shared by pinned GIMP 3.0.8 and
3.2.8 context tables (also source-checked against 3.2.0 and master): all
layer/group entries from `normal-legacy` through
`pass-through`, excluding painting/filter-only `behind`, `behind-legacy`,
`color-erase-legacy`, `replace`, `overwrite`, `anti-erase`. This includes the
legacy variants and `erase/merge/split`, whose actual contexts admit layers.
The exact catalog is `RecorderFileLayerMode.names`; native target-kind/capability
checks still apply when executing. Unknown future tags, fields and versions
refuse the entire file. The writer's semantic switches are exhaustive, so a new
family requires an explicit representation rather than being silently omitted.

Decode returns a complete candidate or throws without mutating caller values or
input bytes; encode returns complete bytes or throws. File storage, the recorder
interface and binding installation are implemented outside the codec and are
outside this document's scope. This document describes the implemented schema
and validation only; it claims no runtime verification and no whole-editor
completeness.


## Physical Lab commands (versions 13 and 14)

`fillLab` contains exactly `tag`, `value` and `opacity`; `applyLabCurves`
contains `tag` and exactly 256 normalized `samples`. Each requires a `lab`
binding with `symbol`, owned `role` (`lightness`, `a`, `b`), `precision`
(`u8`, `u16`, `float`) and a nonzero document-scoped `uuid`. Its symbol must
have a channel description. Integer physical values remain in the nominal
axis range; Float accepts finite values representable by Float. A symbol
cannot mix Lab and ink identity or carry inconsistent Lab identities.

Version 14 adds `completeLabStroke`, with exactly `tag`, `settings`, `facts`,
`first` and `batches`. Settings contain `value` (physical Lab), `size`
(1...10000), `opacity` and `hardness` (0...1). Facts use the ordinary stroke
brush identity and 64 lowercase hexadecimal fingerprint schema. The Lab
fingerprint describes the effective physical stroke configuration, with its
own hash domain; it is not interchangeable with an RGB stroke fingerprint.

Each sample contains `x`, `y`, `pressure`, `xTilt`, `yTilt` and unsigned
32-bit `timeMilliseconds`. Optional `rotationTurns` is in [0,1), and
optional `tangentialPressure` is in [-1,1]. Omission and explicit numeric zero
are distinct. Null, unknown fields and nonfinite numbers refuse the file.
Coordinates are in [-524288,524288], pressure in [0,1], and tilt in [-1,1].
Timestamp deltas use unsigned modular subtraction and cannot exceed
0x7fffffff, including at batch boundaries. Every continuation batch has
1...4096 samples, and the whole stroke has at most 65536 including `first`.
All successful strokes and polygons share the 100000-point file budget.

Lab strokes require the same explicit physical-axis binding as Lab Fill.
Before replay begins, the engine checks the installed brush and captured
configuration. A failed continuation or End cancels the complete Lab stroke.
These are execution checks; a valid file alone never authorizes a target.


## Lab root-mask selections (version 15)

`labSelectionShape` has exactly `tag`, `shape`, `options`. Its rectangle or
ellipse shape contains `tag` and `rect` (`x`, `y`, `width`, `height`); its
polygon contains `tag` and `points` (each exactly `x`, `y`). Options contain
only `operation` (replace/add/subtract/intersect), `antialias`, `feather` and
`cornerRadius`. Both radii must be finite in 0...1000. Coordinates and opposite
rectangle endpoints must be finite in ±1048576. Signed extents and off-canvas
positions remain unchanged; snapped floor/ceil rectangle spans must be positive.
A polygon has 3...65536 points and consumes the shared 100000-point file budget.

`labSelectCommand` has exactly `tag` and `command` (all/none/invert). Both new
tags require binding `none`. Their explicit Lab tag records document-mode
intent; no axis identity is needed for the root mask. Replay calls only typed
Lab selection APIs, so loading on an incompatible document does not permit an
ordinary selection fallback. Version 15 requires a successful new Lab selection
command. Earlier versions and ordinary selection tags retain their existing
semantics; unknown fields, unsupported commands and axis/layer bindings refuse.
