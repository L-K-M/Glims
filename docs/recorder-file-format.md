# Recorder file format, version 1

The pure codec produces and reads detached values for named `.glimsrecording`
files. This slice adds no file I/O, Save/Load interface, live-log installer,
binding interface or automatic crash recovery. A successful decode does not
authorize execution or establish ownership of any open image.

The UTF-8 JSON envelope has exactly `format`, `version`, `recordingID`, `name`,
`origin`, `symbols` and `records`. `format` is `ch.lkmc.Glims.recording` and
`version` is integer `1`. `recordingID` is a file UUID. `origin` contains
`imageLabel`, `initialWidth` and `initialHeight`; these are descriptive hints.
Neither the label nor dimensions prove that a reopened image is the original.

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
| `transformImage` | `transform` |
| `scale` | integer `width`, `height` |
| `resizeCanvas` | integer `width`, `height`, `offset`, `fill` |
| `crop` | `rect` |
| `layerProperties` | `properties` |

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

Bindings are `kind:"none"`, `kind:"layer"` with `symbol`, or `kind:"context"`
with `context`. Layer properties require a layer symbol. Select Alpha and color
selection with `sampleMerged:false` require context; other commands require
none. Context has ordered `layers`/`channels` UUID arrays, `target`, `masks` and
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
- 100,000 polygon points summed across all records.
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

Version 1 owns the 59 layer/group mode tags shared by pinned GIMP 3.0.8 and
3.2.8 context tables (also source-checked against 3.2.0 and master): all
layer/group entries from `normal-legacy` through
`pass-through`, excluding painting/filter-only `behind`, `behind-legacy`,
`color-erase-legacy`, `replace`, `overwrite`, `anti-erase`. This includes the
legacy variants and `erase/merge/split`, whose actual contexts admit layers.
The exact catalog is `RecorderFileLayerMode.names`; native target-kind/capability
checks still apply when executing. Unknown future tags, fields and versions
refuse the entire file. The writer's semantic switches are exhaustive, so a new
family requires an explicit representation rather than being silently omitted.

There is no installer or store in this slice. Decode returns a complete candidate
or throws without mutating caller values/input bytes; encode returns complete
bytes or throws. Atomic disk replacement and live-log replacement remain separate
transactions to implement and verify. New codec tests are authored independently
with literal JSON and a rejection corpus; compilation/runtime are pending at
this source checkpoint.
