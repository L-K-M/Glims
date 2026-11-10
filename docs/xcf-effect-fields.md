# Read-only foreign XCF effect metadata

`Engine/xcf-effect-fields.{c,h}` is a pure GLib/GIO metadata decoder. It
does not include GIMP headers, load an engine, interpret native enums,
restore effects, or modify a file or image. Native correspondence,
validation, restoration and load admission remain separate work.

The owned opaque result exposes const views of the image header, ordered
layers and each layer's ordered effects. Strings remain valid until the
result is freed, independently of the closed input. Layer tattoos include
presence information. Effect presence bits distinguish absent properties
from literal zero values. Paint mode, region and the three blend/composite
fields retain their signed 32-bit words; visibility and clipping retain
their raw unsigned words. No AUTO resolution or native validation occurs.
Ordinary effect-mask presence, dimensions, name and tattoo are metadata too.

The initial scope is a seekable regular local file with an uncompressed
XCF version 22 or 23 header. Ordinary layers and multiple effects are
supported. Layer masks, image channels, paths, groups, nested layers,
specialized layer markers and text-layer parasites fail explicitly.
Ordinary per-effect masks are accepted without reading their pixels;
their hierarchy follows their metadata immediately or after one empty
effects table. Other mask layouts and nested mask effects are unsupported.

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
8192 unique object anchors and 16392 offset reads. Strings require valid
UTF-8 and one trailing NUL. Allocation and traversal stay bounded on
failure; partial results are freed. Format errors distinguish not-XCF,
unsupported scope, malformed data and budget exhaustion. Transport and
close failures retain their GIO error domain.

The pure specifications compile only this module and its GLib/GIO tests:

```sh
python3 scripts/test-xcf-effect-fields.py build --out /tmp/glims-completion/foreign-xcf-pure-build
python3 scripts/test-xcf-effect-fields.py run \
  --binary /tmp/glims-completion/foreign-xcf-pure-build/xcf-effect-fields-tests \
  --fixture /tmp/glims-completion/foreign-xcf-native-baseline-red-20261110/foreign-explicit-effect.xcf \
  --work /tmp/glims-completion/foreign-xcf-pure-run-20261110
```

That initial run passed 47 checks with empty stderr. It reads the preserved
foreign oracle whose SHA256 is
`2bf11d65b4710084996e47255e1b653a488f027d271408040bbd9e15ad2dc095`;
its raw fields must be the independent literals `2, 2, 3`. Owned synthetic
metadata covers multiple layers/effects, negative and unknown raw words,
presence, ownership after input deletion, every fixture truncation,
bad/overlapping/reused offsets, duplicate fields, unsupported shapes and
budgets. A sparse 12 MiB unrelated TLV passes with fewer than 4096 bytes
read. Synthetic hierarchy bytes are deliberately opaque and are never
claimed to be engine-renderable fixtures.

These are metadata proofs only. The existing native 41-check oracle and
its three field failures plus rendered-pixel failure remain unchanged.
No native restoration or all-engine fidelity result follows from this
pure suite. Compressed containers and broader image shapes remain outside
this decoder's initial scope.
