# Read-only foreign XCF effect metadata

`Engine/xcf-effect-fields.{c,h}` is a pure GLib/GIO metadata decoder. It
does not include GIMP headers, load an engine, interpret native enums,
restore effects, or modify a file or image. Native matching,
validation, restoration and load admission remain separate work; no
load hook, facade or input mutation is implemented by this module.

The owned opaque result exposes const views of the image header,
ordered layers in serialized preorder, each layer's ordered effects,
an optional layer mask with its ordered effects, and ordered image
channels with their ordered effects. Strings remain valid until the
result is freed, independently of the closed input. Layer tattoos
include presence information. Layer context flags classify ordinary,
group, text, vector and link layers; text-parasite and marker
detection is classification only and never interprets configuration.
Effect presence bits distinguish absent properties from literal zero
values. Paint mode, region and the three blend/composite fields retain
their signed 32-bit words; visibility and clipping retain their raw
unsigned words. No AUTO resolution or native validation occurs.
Ordinary effect-mask presence, dimensions, name and tattoo are metadata
only, and effects nested on per-effect masks remain unsupported in this
bounded slice.

The scope is a seekable regular local file with an uncompressed XCF
container version 22 through 26. Version 26 carries per-channel
effect-offset tables. Earlier readers do not interpret them, although the
pinned writer can reserve an empty table. Flat serialized
layer preorder retains ordinary, group, text, vector and link context
flags, and an optional layer mask plus ordered image channels expose
owned name, tattoo, dimensions and selection-marker metadata with their
ordered effects through the header accessors. The item-path getter
returns an owned const GArray of raw guint32 entries, or NULL when no
serialized item-path property exists. The paths offset table is
bounded, range-checked and claimed, but path bodies are not interpreted
because paths carry no effect fields. Ordinary per-effect masks are
accepted without reading their pixels; their hierarchy follows their
metadata immediately or after one empty effects table. Other per-effect
mask layouts and effects nested on per-effect masks remain unsupported.

All file bounds, seeks and object offsets use 64-bit positions. Known
singleton fields reject duplicates and incorrect sizes. Object offsets
must be unique; consumed metadata ranges may not overlap each other or
contain another object anchor. No hierarchy or tile payload is read.
Unrelated TLV payloads are range-checked and seek-skipped, including large
image metadata. Their skipped lengths do not consume the read/storage
budget.

The bounds are an 8 MiB charge ledger for actual byte reads and owned
metadata storage, 64 KiB per encoded string including its terminator,
4096 total layer/effect/mask records, 65536 properties/parasite entries,
8192 unique object anchors, 16392 offset reads and 4096 indices per item
path. Strings require valid UTF-8 and one trailing NUL. Allocation
and traversal stay bounded on failure; partial results are freed. Format
errors distinguish not-XCF, unsupported scope, malformed data and budget
exhaustion. Transport and close failures retain their GIO error domain.

The pure specifications compile only this module and its GLib/GIO tests:

```sh
python3 scripts/test-xcf-effect-fields.py build --out /tmp/glims-completion/foreign-xcf-context-pure-build
python3 scripts/test-xcf-effect-fields.py run \
  --binary /tmp/glims-completion/foreign-xcf-context-pure-build/xcf-effect-fields-tests \
  --fixture /tmp/glims-completion/foreign-xcf-native-baseline-red-20261110/foreign-explicit-effect.xcf \
  --saved-corpus .build/foreign-field-adapters/GIMP_3_2_8/test-work \
  --work /tmp/glims-completion/foreign-xcf-context-pure-run-20261110
```

The recorded expanded run passed 75 pure checks with empty stderr. It
reads the preserved foreign oracle whose SHA256 is
`2bf11d65b4710084996e47255e1b653a488f027d271408040bbd9e15ad2dc095`;
its raw fields must be the independent literals `2, 2, 3`. Owned synthetic
metadata covers multiple layers/effects, negative and unknown raw words,
presence, ownership after input deletion, every fixture truncation,
bad/overlapping/reused offsets, duplicate fields, malformed context and
budgets. Newly supported context has positive specifications as well as
malformed counterparts. A sparse 12 MiB unrelated TLV passes with fewer
than 4096 bytes read. Synthetic hierarchy bytes are deliberately opaque
and are never claimed to be engine-renderable fixtures.

The unchanged GIMP-made `composite.xcf` proves the five-layer serialized
tree, text/group classification, child paths `[1,0]` and `[1,1]`, blur and
layer-mask metadata. The saved native `roundtrip`, `effects`,
`edited-effect` and version26 `channel-filter` corpus proves independent
layer counts, multi-effect order, effect masks, selection-channel flags
and channel effects. Expected names/order/counts come from the original
native fixture construction and inspector logs. The driver records and
rechecks every supplied corpus file's hash; those files are never edited.

These are metadata proofs only. The separate immutable native 41-check
oracle evaluates restoration and rendered pixels. No native restoration
or all-engine fidelity result follows from this pure suite. Compressed
containers and effects nested on per-effect masks remain outside this
decoder's scope.
