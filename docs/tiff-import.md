# TIFF thumbnail import

Open and Open as Layers omit main-chain TIFF directories whose
`NewSubfileType` is exactly `FILETYPE_REDUCEDIMAGE` when the same file also
contains ordinary pages. These directories are thumbnail previews. Previously
the noninteractive native loader imported them as editable layers and let
their dimensions enlarge the image. A 64 × 64 image with a tagged 256 × 256
thumbnail consequently opened as a 256 × 256 canvas with two layers.

The adapter uses the existing libtiff dependency to inspect the main IFD
chain. When it finds a mixed chain, it copies the file into a private
directory, rescans the copy and unlinks only those thumbnail directories.
The native loader then reads that copy. The adapter restores the original
imported-file identity and removes the copy after loading. It never writes
the source file or re-encodes pixels. Open as Layers retains its normal
single insertion Undo step.

Unmarked small pages, combined `PAGE | REDUCEDIMAGE` flags and files containing
only reduced-image directories remain intact. Classic TIFF and BigTIFF use
the same policy in either byte order. This is not a size heuristic. Linked
Place keeps its original pathname for future monitored reloads and does not
use this temporary-copy path.

The scan refuses malformed or cyclic chains and chains exceeding 4,096 main
directories. libtiff has a 256 MiB single-allocation limit for these scans;
diagnostics stay local to each open handle. Non-TIFF input follows the
existing native loader path.

## Verification

The independent native fixture reproduced 13 failures before the fix. It
checks canvas size, layer names and dimensions, every literal RGB/alpha
pixel, original-file bytes, and Open as Layers insertion/Undo. Run it with
`python3 scripts/test-tiff-import.py --ref GIMP_3_2_8`; `--adapter-root` selects
an isolated adapter matrix.

`scripts/build-adapter.sh --test` also runs 206 standalone TIFF staging
checks. They cover both byte orders, BigTIFF, first-directory unlinking,
ordinary-page/tag/ICC/orientation preservation, source-file bytes, cleanup,
and malformed/cyclic/over-limit input. The standalone source passed Address
Sanitizer, Undefined Behavior Sanitizer and a leak check.

The native regression passes all 102 checks on GIMP 3.2.8, 3.2.0, 3.0.8
and master, alongside the existing conformance and compressed-XCF tests.
Independent review, hosted CI and combined application/package qualification
are pending. This fix does not
establish native CMYK/Lab editing or full TIFF/PSD round-trip fidelity.

libtiff 4.7.2 is already part of the pinned dependency prefix. Its license
text is included in the generated `Engine-Notices.txt` in the app bundle;
the adapter now links it directly as well as the existing native plug-in.
