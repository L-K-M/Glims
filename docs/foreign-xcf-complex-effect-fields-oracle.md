# Complex foreign XCF effect-field oracle

This is a separate native regression specification for **GIMP 3.2.8 and XCF
v26 only**. It supplements the unchanged ordinary-layer 41-check oracle,
61-check admission suite and 75-check pure metadata suite. Its source is
prepared for independent compilation and execution; source authoring is not
runtime evidence.

The harness is `Engine/tests/foreign-xcf-complex-effect-fields-tests.c`.
There are 43 check sites on the complete successful path. Missing mandatory
shape, operations, masks, effects, finite planes or valid record structure
fails fixture admission and prevents a skipped oracle from passing.

## Independently configured native source

The 8 × 6 RGB image uses `FLOAT_LINEAR` precision. Its native flat layer order
is the group, its child, then the background. The child has an asymmetric
partial-alpha texture, a fractional layer mask and two ordered, noncommuting
effects. A separate fractional saved channel is hidden from the composite.
The image selection is empty and there are no paths.

| Drawable | Effect order and name | Native operation/configuration |
| --- | --- | --- |
| Child | `Complex child Exposure 79afc1` | `gegl:exposure`; black level 0.03125, exposure 0.75 |
| Child | `Complex child Invert 27e8b4` | `gegl:invert-linear` |
| Layer mask | `Complex mask Exposure 619f2c` | `gegl:exposure`; black level 0, exposure −0.5 |
| Saved channel | `Complex channel Invert 03adc7` | `gegl:invert-linear` |

Every effect has opacity 0.625, Multiply mode, an active native effect mask,
clip enabled, drawable region, and literal blend/composite/composite-mode
fields **2, 2, 3**. The harness checks native getters and operation properties
before file I/O. Native stack reversal must visibly change the child result;
restoring the order must restore the exact source snapshot and history.
An all-AUTO counter-oracle must visibly differ for the child, layer mask,
saved channel and image composite. Restoring explicit fields must restore
the exact source. These guards have not yet been witnessed at runtime.

## Foreign bytes without a supplement

The harness finds the native SAVE procedure and calls native `file_save`
directly. It never invokes the Glims save facade or supplement preparation.
The source has no Glims effect carrier, and a binary-safe scan rejects a
Glims namespace anywhere in the original XCF bytes.

The original file is retained as `complex-native-unpatched.xcf`. The pinned
native effect writer has a known varargs mismatch for properties 37, 36 and
35; its original words may be indeterminate. The harness does not infer
intended values from those words or require an unpatched public reopen.

A test-only walker follows the three layer offsets and one saved-channel
offset, requires the child item path, follows its layer mask and all four
effect-mask records, and validates hierarchy geometry and table termination.
It requires the complete effect names, icons, operation names/versions,
property order, opacity/mode/active/clip/region, exact Exposure arguments,
tattoos and mask identities. Sentinel names are an extra uniqueness check;
they never supply patch addresses. Metadata ranges and referenced offsets
must not overlap or repeat. The walker bounds the small file and property
loops, and never decodes tile pixels. It does not call the production pure
decoder or native binder and does not include another fixture's walker.

Only the twelve table-located four-byte payloads of properties **37, 36, 35**
are patched, to **2, 2, 3** for each effect. Every byte outside those 48
eligible positions must remain exact. Some high bytes may already match;
the test does not require 48 actual differences. A second walk must preserve
all structure, config and addresses and find all twelve literal integers.
The foreign oracle is retained separately as `complex-foreign-explicit.xcf`.
`complex-oracle.json` records both complete file hashes, patch offsets and
before/after words, source item identities, native effect getters and hashes
of every captured float plane.

## Public reopen oracle

Only the public `image_open` facade reopens the validated foreign file.
Checks require the exact tree, owners, names, flat order, child path, layer
mask, saved channel and four ordered effects. Layer, layer-mask and saved
channel tattoos must survive. Effect-mask tattoos are recorded before and
after, but native loading converts those saved channels into new effect-mask
objects; numeric tattoo equality is not required for those four converted
objects. Their owners, image, dimensions, names, offsets, visibility and full
raw float buffers remain required.

All five raw planes (background, child, group, layer mask and saved channel)
must match the pre-save source byte for byte. The complete child, layer-mask,
saved-channel and group effect-rendered float buffers, and the complete
native image composite, must also match byte for byte. Their expected values
come from the independently configured native source, before saving or
parsing the foreign bytes. The reopened image must be clean with empty
Undo/Redo, the correct file association and no supplement carrier. Opening it
must preserve the original source's full snapshot, history, file associations
and savepoint, and preserve both original and foreign files byte for byte.

## Isolated commands for Root's authorized validation

From this checkout, with an already built immutable pinned producer:

```sh
python3 -I scripts/test-foreign-xcf-complex-effect-fields.py build \
  --producer /absolute/private-producer/GIMP_3_2_8 \
  --out /tmp/glims-complex-foreign-build

python3 -I scripts/test-foreign-xcf-complex-effect-fields.py run \
  --binary /tmp/glims-complex-foreign-build/foreign-xcf-complex-effect-fields-tests \
  --work /tmp/glims-complex-foreign-work --timeout 120
```

`build` compiles only the new harness and links existing objects. It hashes
the response files, adapter/core objects and declared test/header inputs
before and after, writes `build.json`, and never executes the result or
rebuilds/relinks a producer library. `run` requires the matching binary and
input hashes, uses an empty private work directory and private HOME, cache,
config, data, state, runtime, GIMP and temporary directories, clears inherited
GLIMS/DYLD settings, and bounds execution with process-group TERM/KILL cleanup.
Both stdout and stderr, the native/foreign files and manifest remain available
for Root's independent acceptance. Neither command has been run as part of
this source-only slice. Other engine versions and additional native contexts
are outside this fixture's specified scope.
