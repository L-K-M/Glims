# Preserving CMYK PSD import

File > Open CMYK PSD explicitly preserves the original four process-ink
channels and embedded profile for the supported subset below. Ordinary PSD
Open still uses the upstream appearance importer and converts CMYK to RGB.
The preserving command never falls back to that appearance import.

An imported document requires Save As to a native XCF. Revert repeats the
preserving import until a native Save makes that XCF the current file. Export
does not change this identity. This also holds when a PSD has an incorrect XCF
filename extension: the explicit import intent takes precedence over its name.
An already open appearance import of the same file is a separate document;
opening an existing preserving import focuses its window. Preserving imports
are not added to the ordinary Recent menu, which does not store import intent.

## Native transaction

Facade slot 198 stages the source into one unlinked private file, checking its
descriptor/path identity and size/timestamps before and after copying. Parsing
and decoding read only that immutable spool. These checks detect ordinary file
changes during staging; they are not an atomic snapshot guarantee against a
hostile concurrent writer. The source is never written.

Full ICC admission precedes native image allocation. Samples stream into an
unpublished candidate with fresh channel UUIDs and exact integer storage, then
the completed image is adopted once. All I/O close checks and the final
cancellation check precede publication. Cancellation and failed imports close
the candidate; global busy state and progress remain balanced. Source staging
uses 64 KiB chunks and decoding uses 4,096-sample chunks. Event servicing at
these checkpoints is a polling target, not a hard disk-I/O latency guarantee.

The application counts accepted imports and discarded-result cleanup as file
work. Quit waits for that work, including BUSY retries when destroying an
unadopted result. Older adapters disable the explicit preserving command.

## Structural reader

`cmyk-psd-reader.h` accepts an immutable input length and exact read-at callback.
Inspection returns values and offsets, allocating no image or file-sized
buffer. It accepts PSD version 1, four planar CMYK channels, unsigned 8/16-bit
samples, RAW compression, empty color-mode and layer/mask sections, and exactly
one ICC image resource. Other resources refuse rather than silently losing
metadata. Nonempty Pascal names and arbitrary present padding bytes are valid.
The existing 30,000-pixel dimension, 4 MiB profile and 2 GiB-minus-one file
limits apply. Complete bounds and exact final payload size are checked.

ICC inspection checks declared length, CMYK color space, supported profile
class and signature. A native caller must still validate profile usability
before allocating an image. Synthetic test profiles establish structure only.
Decoding rechecks the input layout and emits at most 4,096 samples within one
row at a time. It converts 16-bit byte order only: zero remains full ink and
unsigned maximum remains paper. It performs no ICC, RGB or transfer-curve
conversion. Failure stops both callback families immediately. Earlier emitted
chunks may exist in a private destination; callers must not publish them.

## Checked scope

An independently written literal producer covers 8/16-bit endpoints and byte
patterns, named/odd-sized resources, widths 1, 7 and 4,097, multiple rows and
all four planes. It also covers truncated headers, malformed section/profile
lengths, duplicate/missing profiles, unsupported modes/compression/layers,
extra trailing bytes, forged layouts and every read/emit failure in a complete
small decode. There are 485 passing optimized checks and 485 passing checks
with AddressSanitizer and UndefinedBehaviorSanitizer on this Mac. Apple ASan
has no LeakSanitizer support; its initial unsupported-option abort is retained
separately and is not a passing run. The reader itself allocates no memory.

Independent source review found no important defect. A minor missing
cross-callback assertion was added without changing the private reader.

Independent native and Swift source reviews found no important issue. The
native preserving-import fixture passes 720 checks on each supported engine;
general conformance, compressed XCF and TIFF checks also pass on all four.
The hosted app fixture passes 62 checks per engine, including exact re-export,
Revert before and after native Save, duplicate-open identity, cancelled Open,
failed adoption and Quit while result cleanup returns BUSY. All 1,623 Swift
tests pass. Final bundle/startup and latest-head CI remain integration gates.

The independent native acceptance fixture can be run against a built adapter:

```sh
python3 scripts/test-native-cmyk-psd-preserve.py \
  --producer /absolute/path/to/adapter/GIMP_3_2_8 \
  --work /absolute/path/to/new-test-output
```

It writes literal PSD fields and samples independently of the product codec,
uses an external CMYK profile, checks exact native samples and XCF persistence,
and compares preview pixels with an LCMS double-percent oracle. All four
engine runs pass 720 checks with zero preview difference for both tested
precisions. It also exercises malformed/unsupported input, cancellation
and reentrant BUSY refusal; it does not establish maximum-size performance or
disk-full, Stop-during-import and adversarial concurrent-write behavior.

Layered/RLE/ZIP PSDs, general PSD metadata preservation and Photoshop numeric
parity are not provided here. The initial ICC-only resource policy also
refuses otherwise flat files with resolution, paths or other resource blocks.
