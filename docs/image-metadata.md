# Image metadata backend (feat/image-metadata)

One bounded backend slice: EXIF/IPTC/XMP tag listing, value reads and
single-tag set/remove through the facade, with typed Swift wrappers. No
UI. The native side uses only adapter-allowed dependencies: the locally
installed GExiv2 0.14 headers, the GUI-free `GimpMetadata` utility
(`libgimpbase/gimpmetadata.h`, `GIMP_TYPE_METADATA` derives from
`GExiv2Metadata`) and the core image metadata API
(`app/core/gimpimage-metadata.h`). `libgimp` and the GUI modules are
never linked or loaded. Zero upstream edits.

## API and ownership

Four additive facade slots appended after slot 123, order preserved;
`GLIMS_ENGINE_API_VERSION` stays 1 (purely additive, `struct_size` grows):

| Slot | Function | Result |
|---|---|---|
| 124 | `image_metadata_tags(engine, image, domain, char ***result, int32_t *count, char **error)` | owned NULL-terminated UTF-8 tag-name vector |
| 125 | `image_metadata_values(engine, image, tag, char ***result, int32_t *count, char **error)` | owned NULL-terminated UTF-8 value vector |
| 126 | `image_metadata_edit(engine, image, tag, operation, const char *const *values, int32_t count, char **error)` | — |
| 127 | `free_metadata_strings(char **strings)` | releases a 124/125 vector |

Owned enums, never native ones: `GlimsMetadataDomain`
(`GLIMS_METADATA_EXIF/IPTC/XMP` = 1/2/3) and `GlimsMetadataEdit`
(`GLIMS_METADATA_SET/REMOVE` = 1/2). Tags cross only as their native
dotted UTF-8 strings (`Exif.…`, `Iptc.…`, `Xmp.…`).

Ownership contract:

- On success of 124/125, `result` is an owned array of `count`
  NUL-terminated UTF-8 strings plus a NULL terminator — never truncated,
  duplicates and order kept. Release with slot 127 (never `free_string`).
  An image with no metadata, or no tag of the asked domain, yields an
  honest **empty** vector: non-NULL array, `result[0] == NULL`,
  `count == 0` — never a NULL `result` on success. On every failure
  `result` is NULL and `count` 0; `error` follows the usual
  `free_string` rule.
- Swift (`EngineSession.metadataTags/metadataValues/editMetadata`)
  decodes the vector into `[String]` (empty array == empty vector, the
  nil/empty distinction is preserved: success never yields nil) and
  releases it with `defer { api.free_metadata_strings(result) }`;
  errors translate through the existing `check`/`free_string` path.

## Semantics

Reads (124/125) borrow the image's own `GimpMetadata`
(`gimp_image_get_metadata`, transfer none) and are plain reads: allowed
at any time, also while a stroke, a filter preview or a plug-in holds
the image (same convention as the other reads); they never create
metadata and never mutate the image or its history.

`image_metadata_edit` (126), one tag only — no wildcard/group form:

1. Resolve the image (NOT_FOUND), then validate the complete request:
   tag non-NULL/non-empty/valid UTF-8 with an `Exif.`/`Iptc.`/`Xmp.`
   prefix, known operation, REMOVE takes no values, SET needs
   `count >= 1` with every value a non-NULL valid UTF-8 string
   (INVALID_ARGUMENT otherwise — an empty set is not a value, REMOVE
   erases). The tag must be registered in the native GExiv2 registry
   (`gexiv2_metadata_try_get_tag_type`); a well-formed but unregistered
   tag is NOT_FOUND with the native registry message, never guessed XML
   handling.
2. Refuse, before any mutation, the tags `gimp_image_set_metadata`
   rewrites from the image's own state (see Normalization below) and
   XMP `LangAlt` tags: UNSUPPORTED with an actionable message. A new
   (absent) XMP `XmpBag`/`XmpSeq`/`XmpAlt` tag is also UNSUPPORTED: a
   plain string vector cannot choose a container type faithfully.
   SET with `count > 1` requires native multi-value support
   (`gexiv2_metadata_try_tag_supports_multiple_values`: repeatable IPTC,
   XMP Bag/Seq/Alt; never any EXIF tag) — otherwise INVALID_ARGUMENT,
   because the native multiple setter would silently keep only the last
   value.
3. No-op detection on the current metadata, before the busy gate (a
   no-op mutates nothing): REMOVE of an absent tag, or SET of the exact
   value list the tag already holds in the same order, returns OK with
   zero undo.
4. `glims_edit_ready` — BUSY while a stroke, a filter preview or a
   plug-in holds the image.
5. Privately duplicate the metadata (`gimp_metadata_duplicate`, or
   `gimp_metadata_new` when the image has none) and apply the native
   set/clear **only on the copy**: REMOVE → `try_clear_tag`; SET →
   `try_set_tag_string` for one value on a non-container tag,
   `try_set_tag_multiple` for containers or multiple values. A native
   failure is FAILED with the native `GError`, the copy is released, and
   the original is untouched (rejection atomicity).
6. Only after success and semantic change,
   `gimp_image_set_metadata(image, copy, TRUE)` — the single native
   setter takes its own reference (verified in
   `app/core/gimpimage-metadata.c`: `g_set_object`) and pushes exactly
   one `GIMP_UNDO_IMAGE_METADATA` step because the copy is never the
   image's own object; the adapter releases its local reference after.
   Undo/redo restore the previous metadata object exactly
   (`app/core/gimpimageundo.c` swaps a duplicate back with
   `push_undo` FALSE, NULL included).

Multivalue and duplicates: reads return the full vector in native order
with duplicates kept; SET on a multi-value tag stores every entry in
order — arrays are never flattened or deduplicated. Language
alternatives: reads of XMP LangAlt tags return the alternative texts
without their `xml:lang` qualifiers (native string-vector behavior,
documented); edits of LangAlt tags are UNSUPPORTED rather than lossy.
Unknown-to-us metadata stays opaque inside the core object — the edit
path duplicates the whole native object, it never reconstructs it from
known tags, so untargeted tags, arrays and alternatives survive edits
and rejections.

## Normalization policy (source-verified)

`gimp_image_set_metadata` (identical in all four engine sets
GIMP_3_0_8/3_2_0/3_2_8/master — diffed) runs
`gimp_image_metadata_update_{pixel_size,bits_per_sample,resolution,
colorspace}` on the new metadata whenever it is non-NULL, rewriting:

- always: `Exif.Image.ImageWidth`, `Exif.Image.ImageLength`,
  `Exif.Image.BitsPerSample`, `Exif.Image.XResolution`,
  `Exif.Image.YResolution`, `Exif.Image.ResolutionUnit`,
  `Exif.Photo.ColorSpace` (set or cleared);
- when already present: `Exif.Photo.PixelXDimension`,
  `Exif.Photo.PixelYDimension`, `Xmp.exif.ColorSpace`,
  `Exif.Iop.InteroperabilityIndex`, `Exif.Nikon3.ColorSpace`,
  `Exif.Canon.ColorSpace`.

Policy: the facade refuses SET and REMOVE on exactly those 13 tags with
UNSUPPORTED, so a requested value can never be overridden by
normalization, and success is never claimed for an overridden value.
Honest corollary: the first metadata edit on an image that had no
metadata creates the metadata object, and the same normalization then
fills those tags from the image's state — native behavior, documented
here, not a requested-value override. Undo/redo also run the
normalization on the restored object with `push_undo` FALSE; with
unchanged image geometry/resolution it writes back the same values.

## Source references

- `_deps/macports/include/gexiv2/gexiv2-metadata.h` (GExiv2 0.14.7):
  `try_get_tag_type`, `try_tag_supports_multiple_values` ("no multiple
  value Exif tags"), `try_get/set_tag_multiple` (multiple tags store each
  entry; single-value tags keep only the last), `try_clear_tag`,
  `get_{exif,iptc,xmp}_tags`.
- `_engine/src/<ref>/gimp/libgimpbase/gimpmetadata.{h,c}`:
  `gimp_metadata_new/duplicate` (duplicate = serialize/deserialize,
  keeps every present tag), `gimp_metadata_is_tag_supported`.
- `_engine/src/<ref>/gimp/app/core/gimpimage-metadata.{h,c}`:
  `gimp_image_get_metadata` (borrowed), `gimp_image_set_metadata`
  (ownership, one undo, normalization), all four sets byte-identical.
- `_engine/src/<ref>/gimp/app/core/gimpimageundo.c`:
  `GIMP_UNDO_IMAGE_METADATA` snapshots/restores a duplicate.
- `_engine/src/GIMP_3_2_8/gimp/plug-ins/metadata/metadata-editor.c`:
  reference for native set/clear usage (GUI code, reference only).

## Tests

- `Engine/tests/engine-tests.c` `test_image_metadata` (facade-only, no
  GIMP headers): honest empty owned reads on a metadata-less image;
  invalid domain/tag/UTF-8/count/NULL; unknown image and unregistered
  tag; EXIF set + readback + tag list; identical-set no-op; unrelated
  tag survival; IPTC repeatable multivalue order and duplicates; EXIF
  multi-value refusal; empty-SET vs REMOVE; unknown operation; XMP text
  set; LangAlt / new-container / protected-tag UNSUPPORTED; REMOVE +
  absent-remove no-op; exact undo/redo restoration; BUSY under a stroke
  and a filter preview with reads still allowed; rejection atomicity
  (history unchanged); XCF save/reopen retention of EXIF/IPTC/XMP tags
  and multivalue order; closed-image NOT_FOUND; `free_metadata_strings
  (NULL)`.
- `Tests/GlimsKitTests/EngineMetadataTests.swift`: pure wrapper
  contract tests (enum raw values against the C header, string-vector
  decoding incl. nil/empty/count-bounded). No engine started.

## Checks actually run (this change)

- `swift build -j 2 --build-tests` — compiles the facade header into
  CGlimsEngine, the Swift wrappers and the new test file.
- `clang -fsyntax-only` on `Engine/metadata.c` with the pinned engine's
  own adapter compile flags (from `_engine/adapter/GIMP_3_2_8/
  compile.rsp`) and on `Engine/tests/engine-tests.c` with the facade
  include only. Syntax-only; no objects written outside the build tree.

NOT run here (root owns runtime/native execution): the adapter build
(`scripts/build-adapter.sh`), the native conformance suite
(`glims-engine-tests`, including `test_image_metadata`), the app
smoke tests, and `swift test`. No runtime behavior is claimed beyond
what the sources above state.

## Known limits / untested cases

- LangAlt reads drop `xml:lang` qualifiers (native string vector); edits
  of LangAlt are refused UNSUPPORTED — not covered by a positive
  round-trip test because the facade cannot create them.
- New XMP Bag/Seq/Alt tags cannot be created through this API
  (UNSUPPORTED); editing an existing container is implemented but not
  exercised by the conformance test (no fixture carries one).
- `gimp_metadata_duplicate` goes through the native
  serialize/deserialize; the `Xmp.photoshop.DocumentAncestors` > 1000
  cap in `gimpmetadata.c` is native behavior inherited verbatim.
- Protected-tag refusal is tested for `Exif.Image.ImageWidth` (SET) and
  `Exif.Image.XResolution` (REMOVE); the other 11 tags share the same
  code path.
- Normalization filling the dimension/resolution/bits/colorspace tags
  on the first edit of a metadata-less image is documented from source,
  not asserted by a runtime test here.

Root acceptance checkpoint: a counted input vector with a fourth,
unrequested trailing value reproduced reading beyond the public count.
The adapter now builds a private count+1 terminated vector for GExiv2;
requested three-value order and duplicates survive. Swift rejects embedded
NULs before bridging tags or values. Two pure input checks pass.

The native XML duplicate can shorten some metadata. Every write now verifies
the complete copied tag catalog and EXIF/IPTC raw values; XMP uses the whole
generated packet so language qualifiers and containers participate. Core's
protected image facts compare logical values because native duplication can
change EXIF integer width (ColorSpace was observed as four versus two bytes).
A second duplicate checks that the edited object can survive Undo and save.
An unverifiable or changed copy is refused before replacing the image.

Pinned conformance passes after these changes. Initial remaining fixture
failures assumed a new image had zero default EXIF tags and forgot the Undo
step created by the busy-check stroke before the preview case. The fixtures
now inspect the actual owned catalog and snapshot Undo depth after that stroke.
Positive existing-LangAlt/container and overlong-ancestor preservation cases
remain unverified; the copy guard does not count as evidence for those fixtures.
