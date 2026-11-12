# Preserving CMYK PSD import

This candidate is private parsing preparation. Ordinary PSD Open still uses
the upstream appearance importer and converts CMYK to RGB. The reader has no
public image or application entry point; it does not yet fix that workflow.

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
cross-callback assertion was added without changing production code. Native
compatibility and hosted CI remain integration gates for this candidate.

Next work is an explicit preserving native import transaction with immutable
input staging, full ICC validation, unpublished component storage and balanced
cancellation. The app must preserve that import choice through Revert until
native XCF Save changes the current file. Layered/RLE/ZIP PSDs, general PSD
metadata preservation and Photoshop numeric parity are not provided here.
