# Read-only foreign XCF effect metadata

`Engine/xcf-effect-fields.{c,h}` is a pure GLib/GIO metadata decoder. It
does not include GIMP headers, load an engine, interpret native enums,
restore effects, or modify a file or image. Native matching,
validation, restoration and load admission belong to the separate services
described below; this module implements no load hook, facade or input mutation.

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

The metadata reader accepts a seekable regular local XCF from version
20 through 26. The gzip recovery path stages the inner XCF for this
same reader. Versions 20 and 21 have no serialized
operation version. On those versions the native correspondence check still
requires the exact operation name and all other existing fields. Versions
22 and later retain the operation-version check. Version 26 carries per-channel
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

## Native restoration and recorded validation (2026-11-10 candidate)

The separate `foreign-effect-load` and `foreign-effect-state` services now
recover these three fields before a foreign image is adopted. The binder
matches the complete loaded image, serialized layer preorder and item paths,
layer masks, channels, ordered real effects, operation versions, unchanged
settings and normalized effect-mask ownership/dimensions. It collects every
target before applying any field setter; a mismatch refuses the unpublished
image. It adds no Undo, supplement, pixel/mask edit or source-file write.
Glims-authored supplements continue through their existing validated loader.

Registered nonnegative words retain their native enum values. A negative
effective enum returns to AUTO only when the loaded mode still has that default;
otherwise it becomes explicit. INT32_MIN is refused before negation. There
is one narrow native-writer compatibility case: three present, identical
words whose absolute value is unregistered in both native enum types may
retain three already-loaded AUTO values. The pinned writer can emit that
uninterpretable triplet through a varargs mismatch. This does not recover
unknown values, admit mixed invalid words, or replace registered explicit
values with AUTO.

For plain XCF, the loader compares pre-load and post-decode file size,
required ETag and available device/inode attributes. This detects ordinary
observable changes. It does not bind both plain-XCF reads to one descriptor.
Gzip uses the shared spool described below. Missing required identity
evidence refuses recovery. The reader's bounds apply
to plain XCF v20–26 and to the inner XCF of a single gzip member.
Bzip2, xz, nested compressed wrappers and effects nested on effect masks
remain outside recovery. The native loader may discard unsupported effects
before recovery can run.

The preserved native runs, checked against their manifests at source
`946ded1`, record:

| Evidence | Result and scope |
| --- | --- |
| Pure metadata suite | 75/75; empty stderr, unchanged fixture hashes. |
| Ordinary foreign oracle | Original native baseline: 37/41, with the three literal fields and rendered pixels failing. Its unchanged 41 checks are included in the passing admission suite. |
| Native admission v2 | 61/61 on 3.2.8; atomic refusal, invalid/absent/negative fields and the exact writer-compatibility boundary. |
| Independent complex oracle | Same harness: original 3.2.8 producer 35/43; context-aware producer 43/43. |
| General conformance | 1,917 each on 3.2.8, 3.2.0 and master; 1,703 on 3.0.8, all with zero failures. |
| Existing XCF supplement fidelity | 121/121 on each of those four engines. |
| Actual-menu compatibility smoke | Selective Gaussian Blur: 28 checks on the context-aware 3.2.8 prefix, exit 0; app exited and desktop released. This is not a foreign-file GUI test. |

The complex oracle is specifically native 3.2.8/XCF v26. Its independently
configured source has a group/child tree, two noncommuting child effects,
layer-mask and saved-channel effects, and four native effect masks. Its
test-only walker patches only the twelve serialized field payloads to
literal `2, 2, 3`; expected pixels come from the configured native source,
not the production decoder. All four reopened triplets equal those literals.
Five raw planes and every captured rendered plane match their own pre-save
source byte for byte; child, layer-mask, channel, group and composite float
deltas are all zero. Source/file/history checks also pass. Different runs
generate their own source files and expectations; native indeterminate writer
words and cross-run source hashes are not expected to match. See the
[complex oracle specification](foreign-xcf-complex-effect-fields-oracle.md).

An initial strict implementation failed ten general checks by rejecting
existing group/channel fixtures and the native writer's invalid triplets.
Those compatibility failures were fixed before the passing matrix above.
The original 41-check fixture, admission v2 fixture and pure 75-check fixture
remain unchanged after the complex addition; `9d8a1d8` had already moved
admission work onto the existing engine worker without changing its oracles.
Production bytes are unchanged since `7498267`.

Local evidence is indexed in
`/tmp/glims-completion/foreign-xcf-context-complex-results.json`, including
the prior all-four manifest, per-run logs/hashes and source-only audits.
Separate loader and context-binding audits found no additional confirmed
important issues within their recorded scopes. This documentation/evidence
pass is not another independent approval: its author wrote the initial
binder. Normal foreign-file GUI acceptance, latest-head CI/review and PR
integration remain separate gates; the broader foreign-preservation ledger
item stays open.

## API165 integration verification (2026-11-10)

Fresh immutable adapters from `c0acf2d` append the inherited batch slot165
without changing the seven foreign-reader/binder production files from
`2de536b`. General conformance again passes1,917/1,917/1,703/1,917 checks
on3.2.8/3.2.0/3.0.8/master. The original41-check and complex43-check
foreign oracles pass again on the new pinned3.2.8 tuple. This is not a fresh
all-four complex-oracle claim; earlier61/75/121 results retain their original
producer scope. Logs/hashes are in
`/tmp/glims-completion/foreign165-integration-verification.json`.

A bounded independent Glyph source review at`2de536b` covered all seven
foreign production files and all19 changed-file fingerprints without a
confirmed important finding. Its source parity scope excludes authentic
GIMP loader ordering, covered separately by the recorded loader/binding
audits. The hosted reviewer at`2de536b` timed out before publication; no
partial hidden findings are claimed reviewed and the timeout is not approval.
Latest Main integration adds only source collectors.

A separate ordinary LaunchServices document-open event accepted the complex
8×6 foreign file with three layers in the app, then exited cleanly. The
File > Open panel choose-file route remains unverified; this event does not
stand in for that interaction or a final self-contained release workflow.
Nested effect masks and stronger file attestation remain outside the
current scope.

## Legacy effect records

The pinned native oracle constructs versions 20 and 21 from its validated
version 22 fixture by omitting the operation-version string. It keeps the
effect TLVs, mask location and pixel payloads. Direct GIMP loading accepts
both inputs and identifies the native effect. On the old adapter, both
Glims opens refuse. The corrected 3.2.8 adapter passes all 61 native checks,
including the original 41 checks. Legacy results match the independently
configured native effect, source and rendered pixels, retain the mask,
start with empty Undo/Redo, and leave the files unchanged. The pure suite
passes 78 checks with the preserved native corpus. The other engine builds
exercise general conformance; the legacy native oracle is pinned to 3.2.8.

## Gzip-wrapped effect records

The loader opens one local regular source descriptor and compares its
size, device and inode with the original file stamp. It checks the gzip
signature and decoded XCF prefix before dispatching the native load.
For XCF, it decodes one complete member into a private seekable spool,
checks the trailer, rejects trailing data and limits input and decoded
output separately to 4 GiB. The loader unlinks the spool before writing
any image bytes and closes it when the open finishes.

GIMP's XCF stream loader and the bounded effect reader read the same
decoded spool. Replacing the original pathname between their reads
cannot mix one image's pixels with another image's effect settings.
GIMP receives the original `GFile` for image identity, Save and Revert,
and as the base for resolving relative linked files. The source stamp
is checked again before publication. Glims supplements and images
without effects skip the foreign metadata reader. The original native
loader still handles other gzip formats, with foreign XCF effect
recovery disabled on that fallback.

The pinned 3.2.8 fixture switches a private alias from A to B immediately
before native load, then back to A before metadata recovery. The two XCFs
have the same topology and different pixels and fields. The old adapter
failed two of 117 checks: native pixels came from B while restored effect
fields came from A. The shared-spool adapter passes all 117 checks. It
keeps A's raw and rendered pixels, fields and mask; the original alias,
load procedure and clean opening history; and both source files' bytes.
The nine private gzip checks pass, as do general conformance checks on
3.2.8 (1,917), 3.2.0 (1,917), 3.0.8 (1,703) and master (1,917).

The fixture verifies the lexical parent passed to the native loader. It
does not freeze separate linked assets or test opening one, nor does it
exercise Save and Revert through the app. The plain XCF route still uses
separate native and metadata reads with its existing source stamp checks.
Bzip2, xz and nested effect-mask cases remain outside this change.
