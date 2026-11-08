# Metadata tag descriptors (feat/metadata-tag-info)

One bounded READ-ONLY backend slice on top of the image-metadata facade
(`docs/image-metadata.md`): a descriptor of one registered tag, appended
as facade slot 128. No UI — the Metadata UI adopts descriptors separately.
No change to any existing slot's behavior.

## API 128 and ownership

One additive footer function, appended after slot 127; the existing 127
slots, their order and `GLIMS_ENGINE_API_VERSION` (1) are unchanged —
the change is purely additive, `struct_size` of `GlimsEngineAPI` grows:

| Slot | Function | Result |
|---|---|---|
| 128 | `image_metadata_tag_info(engine, image, tag, GlimsMetadataTagInfo *outInfo, char **error)` | read-only descriptor in `outInfo` |

`GlimsMetadataTagInfo` is facade-owned and size-versioned like the other
out structs: the caller sets `struct_size = sizeof (GlimsMetadataTagInfo)`
before the call; the adapter refuses a NULL `outInfo` or a smaller
`struct_size` with INVALID_ARGUMENT **before writing anything** (no write
ever goes past the caller's declared struct size). Once the size check
passes, every later failure resets the struct to a safe all-zero
descriptor. Fields:

- `present` (bool): the image's metadata currently holds the tag.
- `supports_multiple` (bool): the tag can hold several values natively
  (`gexiv2_metadata_try_tag_supports_multiple_values`).
- `value_kind` (`GlimsMetadataValueKind`, facade enum 1-6):
  `SINGLE`, `REPEATABLE`, `BAG`, `SEQ`, `ALT`, `LANG_ALT`.
- `format_policy` (`GlimsMetadataFormatPolicy` bits):
  `SUPPORTS_SET = 1<<0`, `SUPPORTS_REMOVE = 1<<1`.
- `label`, `description`, `type_name`: bounded UTF-8 strings explaining
  the native tag (the registry's own label/description/type name).

Capacities are defined in the facade:
`GLIMS_METADATA_TAG_INFO_LABEL_CAPACITY` 256,
`GLIMS_METADATA_TAG_INFO_DESCRIPTION_CAPACITY` 512,
`GLIMS_METADATA_TAG_INFO_TYPE_NAME_CAPACITY` 64 (each including the NUL
terminator). Only these three strings are bounded; the requested `tag`
string itself is never truncated. Truncation cuts at most to
capacity - 1 bytes, always NUL-terminates and never inside a multi-byte
UTF-8 character (the copy backs off while the first excluded byte is a
continuation byte). Native strings that are not valid UTF-8 are refused
with FAILED and an explicit message — invalid native bytes are never
copied silently.

No raw GIMP/GExiv2 enums, macro values or struct layouts cross the seam:
the native type name crosses only as the bounded `type_name` string, and
the classification maps only the five structural native type names
(`LangAlt`, `XmpBag`, `XmpSeq`, `XmpAlt`) to container kinds; every other
native type name (Exif/Iptc scalars, `XmpText`, anything future) maps
through the native multiple-value capability to `REPEATABLE` or
`SINGLE`. In Swift an unknown `value_kind` raw value throws
(`EngineSession.decodeMetadataTagInfo`), never coerces to an unrelated
kind.

## Classification and flags vs actual edit refusal

`value_kind` and `format_policy` are computed in `Engine/metadata.c` from
the same shared predicates the edit path uses (`valid_tag_name`,
`metadata_tag_protected`, `xmp_container_type`, `lookup_tag_type` — one
local seam, no duplicated policy drift). The policy bits mirror the
edit path's pre-mutation refusals exactly:

- normalization-protected tags (the 13 tags `gimp_image_set_metadata`
  rewrites from the image's own state): no bits — SET and REMOVE both
  refuse UNSUPPORTED;
- LangAlt tags: no bits — both refuse UNSUPPORTED (xml:lang qualifiers
  cannot be represented faithfully);
- an absent XMP container (Bag/Seq/Alt the image does not hold): SET bit
  clear (a new container needs a chosen array type), REMOVE bit set
  (removing an absent tag is a no-op);
- every other registered tag: both bits.

The bits express TYPE/FORMAT POLICY ONLY. An actual
`image_metadata_edit` can still refuse with BUSY (stroke, filter
preview, plug-in), LOCKED, the copy-preservation guard, or other native
validation — e.g. the current edit path's container guard refuses even
REMOVE of an absent container with UNSUPPORTED before its no-op
detection. A set bit never promises a write succeeds.

## Read-only behavior

Slot 128 is a plain read, like slots 124/125: allowed at any time,
also while a stroke, a filter preview or a plug-in holds the image —
there is deliberately no `glims_edit_ready` gate on reads. It borrows
the image's own `GimpMetadata` (`gimp_image_get_metadata`, transfer
none); when the image has none, presence and multiple-value questions
are answered on a PRIVATE empty `GimpMetadata` (`gimp_metadata_new`)
that is unref'd on every path and never installed on the image. The
descriptor read never creates metadata on the image, never marks it
dirty, pushes no undo/history step and mutates no pixels.

Statuses match the existing metadata slots: INVALID_ARGUMENT for a NULL
or undersized `outInfo`, or a `tag` that is NULL, empty, not valid UTF-8
or carries no `Exif.`/`Iptc.`/`Xmp.` prefix; NOT_FOUND for an unknown
(stale/closed) image or a well-formed but unregistered tag (the native
registry decides, with its message); FAILED with the native `GError`
when a native read fails or a registry string is not valid UTF-8.

## Native primary references

- `_deps/macports/include/gexiv2/gexiv2-metadata.h` (GExiv2 0.14.7):
  `gexiv2_metadata_try_get_tag_type`, `try_get_tag_label`,
  `try_get_tag_description` (static registry queries, transfer none),
  `try_has_tag`, `try_tag_supports_multiple_values` ("Multiple value
  tags are Xmp tags of type XmpAlt/XmpBag/XmpSeq or LangAlt, or Iptc
  tags marked as Repeatable … There are no multiple value Exif tags").
- exiv2 0.28.9 source (shared distfiles, read-only):
  `src/types.cpp` type names (`Ascii`, `XmpText`, `XmpAlt`, `XmpBag`,
  `XmpSeq`, `LangAlt`), `src/properties.cpp` (`dc.creator` = seq,
  `dc.subject` = bag, `dc.title`/`dc.description`/`dc.rights` =
  langAlt; no built-in property uses plain `xmpAlt` in this build),
  `src/tags_int.cpp` (Exif `Artist`: asciiString, label "Artist").
- `_engine/src/<ref>/gimp/libgimpbase/gimpmetadata.h`:
  `gimp_metadata_new` (private empty probe), `GIMP_TYPE_METADATA`
  derives from `GExiv2Metadata`.
- `_engine/src/<ref>/gimp/app/core/gimpimage-metadata.h`:
  `gimp_image_get_metadata` (borrowed).

## Swift wrapper

`EngineSession.metadataTagInfo(_:tag:)` (slot 128) reuses the existing
metadata input guard (`validateMetadataStrings`, rejecting embedded NULs
before the bridge), the existing `check`/`free_string` error path and
`struct_size` loading rules. It decodes into the typed
`EngineSession.MetadataTagInfo` with the own `MetadataValueKind` enum
and `MetadataFormatPolicy` OptionSet; decoding goes through
`decodeMetadataTagInfo(from:)`, which throws on an unknown value kind.
No raw native enums or XML schema cross into Swift.

## Tests

- `Tests/GlimsKitTests/MetadataTagInfoTests.swift`: pure contract tests,
  no engine started — enum/bit raw values against the C header, unknown
  kind decode throws, bounded UTF-8 string decode to the NUL terminator
  (multi-byte codepoints included), shared embedded-NUL guard.
- `Engine/tests/engine-tests.c` `test_image_metadata_tag_info`
  (facade-only, no GIMP headers): real `Exif.Image.Artist` and
  `Iptc.Application2.Keywords` facts on a metadata-less image (still a
  pure query — no metadata created, no undo, no dirty change); absent
  XmpBag/XmpSeq (REMOVE-only policy) and LangAlt (no bits); protected
  tags (no bits); presence after a supported SET; edit refusals matching
  the bits where safe (SET on an absent container UNSUPPORTED; REMOVE of
  it mutates nothing); NULL/empty/invalid-UTF-8/prefix-less/unregistered
  tags; NULL and undersized `outInfo` (poisoned-buffer check: the
  refusal writes nothing); unknown and closed image NOT_FOUND; reads
  during an active stroke and filter preview with metadata/undo/pixels
  unchanged.

Coverage gaps, stated honestly: no registered tag in exiv2 0.28.9 has
type `XmpAlt` (source-verified in `properties.cpp`), so the `ALT` kind
is covered only by the classification logic and the Swift enum tests,
not by a live tag; and no fixture carries a label/description longer
than its capacity, so the UTF-8-safe truncation path is covered only by
source, not by a long-string runtime fixture. The plugin-read (busy)
path is exercised for the descriptor read itself (allowed during a
stroke/preview), not through a running plug-in dialog.

## Checks actually run (this change)

- `swift build -j 2` and `swift build -j 2 --build-tests` — compiles the
  facade header into CGlimsEngine, the adapter-facing Swift wrapper and
  the new tests. `swift test` NOT run (root owns it here).
- ONE private native compile:
  `GLIMS_ADAPTER_ROOT="$PWD/.build/engine-adapters" scripts/build-adapter.sh GIMP_3_2_8`
  (no `--test`/`--perf`/`--check`), after a single check that the shared
  `_engine/.lock` was free. All native outputs stayed in this worktree's
  private `.build/engine-adapters/`; the shared `_engine/`/`_deps/`
  trees and libraries were not touched.

NOT run: the conformance suite (`glims-engine-tests`, including the new
`test_image_metadata_tag_info`), the adapter builds against the other
three engine sets (root owns the four-version runtime), the app smoke
tests and any GUI. No runtime result is claimed beyond what the sources
above state; the C conformance expectations are source-derived (exiv2
0.28.9 registry tables plus the existing `test_image_metadata`
behavior), not observed runs.
