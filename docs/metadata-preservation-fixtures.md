# Metadata preservation fixtures (.gmeta loader + oracle)

Test-only fixtures for the copy-preservation guarantees of
`glims_image_metadata_edit` (`Engine/metadata.c`): a positive
LangAlt/XmpBag/XmpSeq preservation fixture and the >1000
`Xmp.photoshop.DocumentAncestors` refusal. Three files, no production
change:

- `Engine/tests/metadata-loader.py` — the throwaway GIMP 3 Python plug-in
  (fixture only; never shipped, installed under the test user's `plug-ins`
  before `engine.start`).
- `Engine/tests/engine-tests.c` — `install_metadata_loader_plug_in()`
  (installs the plug-in before `api->start`, next to the slow-load fixture),
  `test_metadata_preservation_fixtures()` and its helpers, plus the two
  wiring lines in `main` (`GLIMS_GMETA_DIR` env, test call).
- this document.

## Why a raw PDB seed path instead of the public serialization

The public metadata APIs serialize: `Gimp.Image.set_metadata()` /
`Gimp.Metadata.serialize()` go through `gimp_metadata_serialize()`
(`_engine/src/<ref>/gimp/libgimpbase/gimpmetadata.c`), which caps
`Xmp.photoshop.DocumentAncestors` at its first 1000 values
(`gimp_metadata_serialize`, the `cnt > 1000` branch; the parser,
`gimp_metadata_deserialize_text`, likewise drops values once the tag holds
more than 1000, so it keeps at most 1001). Seeding the ancestors fixture
through any serializing wrapper would silently produce 1000 values and the
test would only ever see already-truncated input — a fake pass.

The loader therefore seeds through the Core PDB procedure
`gimp-image-set-metadata` (`app/pdb/image-cmds.c`, `image_set_metadata_invoker`:
`gimp_metadata_deserialize(metadata_string)` then
`gimp_image_set_metadata(image, metadata, TRUE)`) invoked directly with a
procedure config — `config.set_property('image', image)` and
`config.set_property('metadata-string', xml)` — exactly the way libgimp
itself calls it (`libgimp/gimpimage_pdb.c` calls `"gimp-image-set-metadata"`
over the PDB) and the way GIMP's own Python plug-ins run PDB procedures
(`plug-ins/python/file-openraster.py`: `lookup_procedure` +
`create_config()` + `set_property` + `run(config)`). The raw XML reaches
`gimp_metadata_deserialize` uncapped by any prior serialization.

## The raw XML shape (read from the primary sources, not guessed)

`gimp_metadata_serialize` / `gimp_metadata_deserialize`
(`libgimpbase/gimpmetadata.c`) use a GMarkup format:

```xml
<?xml version='1.0' encoding='UTF-8'?>
<metadata>
  <namespace prefix="dc" url="http://purl.org/dc/elements/1.1/"></namespace>
  <tag name="Xmp.dc.title">lang="x-default" Default title &amp; &lt;demo&gt;</tag>
  <tag name="Xmp.dc.title">lang="fr-FR" Titre français — café</tag>
  ...
</metadata>
```

- `<namespace prefix="..." url="..."/>` registers an XMP namespace
  (`gexiv2_metadata_try_register_xmp_namespace`).
- Each `<tag name="...">text</tag>` is one value; repeated tags of one name
  accumulate through `gexiv2_metadata_try_get_tag_multiple` +
  `try_set_tag_multiple` in the parser's text handler.
- Value text is XML-escaped (`& < >` in the loader via `xml.sax.saxutils.escape`;
  the core serializer's `g_markup_escape_text` additionally escapes `' "` —
  both forms parse back identically).
- exiv2 0.28.9 value syntax (the pinned dependency of GExiv2 0.14.7, read
  from `value.cpp`): `LangAltValue::read` parses a leading `lang="fr-FR" `
  qualifier into the alternative's `xml:lang`; `XmpTextValue::read` parses
  `type="Bag"/"Seq"/"Alt"` array indicators. GIMP's own metadata editor
  relies on the same syntax (`plug-ins/metadata/metadata-editor.c`,
  `lang_default = "lang=\"x-default\""`). So a `<tag>` value of
  `lang="fr-FR" Titre ...` seeds a genuine `xml:lang="fr-FR"` alternative.
- Tag types come from the exiv2 registry (`src/properties.cpp`):
  `Xmp.dc.title`/`Xmp.dc.description` are `langAlt`, `Xmp.dc.subject` is
  `xmpBag`, `Xmp.dc.creator` is `xmpSeq`, `Xmp.photoshop.DocumentAncestors`
  is `xmpBag`.

## Fixture contents

Mode file `<work>/gmeta-mode` (written by the C test before each
`image_open`) selects the seed; the loader refuses any other mode with
EXECUTION_ERROR. The `.gmeta` file content itself is irrelevant.

- `qualified`: `Exif.Image.Artist` = `Original Artist`;
  `Iptc.Application2.Keywords` = `iptc-one`, `iptc-two`;
  `Xmp.xmp.CreatorTool` = `Glims fixture`;
  `Xmp.dc.title` (LangAlt) = `lang="x-default" Default title & <demo>` and
  `lang="fr-FR" Titre français — café` — two DISTINCT language keys with
  distinct texts, one containing XML-special characters;
  `Xmp.dc.subject` (XmpBag) = `alpha`, `beta`, `gamma`;
  `Xmp.dc.creator` (XmpSeq) = `creator-one`, `creator-two`.
- `ancestors`: `Exif.Image.Artist` = `Ancestor Artist`, one IPTC keyword,
  and exactly 1001 `<tag name="Xmp.photoshop.DocumentAncestors">` values
  `ancestor-0000` … `ancestor-1000`. The parser keeps at most 1001 (it drops
  only once the tag holds > 1000), so 1001 tags seed exactly 1001 values.

## Oracle comparison (why, and its exact limit)

The facade value read (`image_metadata_values`, slot 125) returns the native
string vector, which for a LangAlt carries exiv2's textual form
(`lang="..."`-prefixed alternatives, per GExiv2 0.14.7
`gexiv2_metadata_get_xmp_tag_multiple`), not the raw `xml:lang` attributes.
Counting or matching texts alone would not prove qualifier fidelity, so the
test also runs the fixture-only `plug-in-glims-meta-oracle` image procedure
through the facade `procedure_run` (which fills run-mode/image/drawables;
the run is synchronous). The oracle invokes the Core PDB
`gimp-image-get-metadata` (`app/pdb/image-cmds.c`,
`image_get_metadata_invoker` → `gimp_metadata_serialize`) and writes the
XML to `<work>/gmeta-oracle.xml`. In that XML each LangAlt alternative is its
own `<tag>` line with an escaped `lang=&quot;fr-FR&quot;` prefix, and each
container value its own line in order; the C test asserts those lines
exactly and in order (`text_has_lines_in_order`) after the seed, after the
unrelated edit, after Undo, after Redo, and after XCF save/reopen — plus the
facade vector equality for texts, bag/seq order, EXIF and IPTC values.
Limit, stated honestly: the oracle is GIMP's serialized form, not the raw
XMP packet; the container *type* (Bag vs Seq) is re-derived from the exiv2
registry on deserialize rather than asserted from the XML, and the oracle
must not be run on the ancestors image because that getter also serializes
(and caps) — the ancestors fixture is verified through the facade read only.

## The 1001-before-refusal requirement

The ancestors test first reads `Xmp.photoshop.DocumentAncestors` through the
facade (slot 125 — a direct `gexiv2_metadata_try_get_tag_multiple` on the
live object, never serialized) and asserts the vector is exactly 1001
values, `ancestor-0000`…`ancestor-1000` in order, NULL-terminated — BEFORE
any write. Then an unrelated `Exif.Image.Artist` SET must return
`GLIMS_STATUS_UNSUPPORTED` (the production guard `metadata_equal_native`
in `Engine/metadata.c` compares the full generated XMP packets of the
original and its `gimp_metadata_duplicate` copy; the copy's serializer caps
the ancestors at 1000, the packets differ, and the edit is refused before
any mutation) with the undo depth unchanged, all 1001 values still exact,
and the unrelated EXIF/IPTC tags unchanged. No fake pass: the input is never
pre-truncated by a serializing API.

## Ownership, paths and cleanup

- The plug-in is copied from `Engine/tests/metadata-loader.py`
  (`argv[3]` = `Engine/tests/fixtures`, so `argv[3]/../metadata-loader.py`)
  to `<user>/plug-ins/glims-metadata-loader/glims-metadata-loader.py`
  (mode 0755) before `api->start`, like the slow-load fixture; the engine
  process inherits `GLIMS_GMETA_DIR=<work>` from the test binary's `setenv`.
- All fixture state lives under the test work dir: `gmeta-mode`,
  `fixture-qualified.gmeta`, `fixture-ancestors.gmeta`, `gmeta-oracle.xml`,
  `metadata-preservation.xcf`, and the throwaway `<work>/user` home. No real
  user HOME, defaults, network or GUI are touched.
- In C: every facade string vector is released with
  `free_metadata_strings`, every `error` with `free_string`, oracle buffers
  with `free`, and every opened image is closed (the test returns early only
  when an open failed, so there is nothing to close). The loader checks the
  PDB result status of both `gimp-image-set-metadata` and
  `gimp-image-get-metadata` and reports EXECUTION_ERROR otherwise; the C
  side checks `image_open`/`procedure_run` statuses.
- Bounded waits: none added; `procedure_run` is synchronous. No sleeps.

## Checks actually run for this change

- `xcrun clang -std=c11 -O2 -Wall -Wextra -Werror
  -I Sources/CGlimsEngine/include -fsyntax-only Engine/tests/engine-tests.c`
  (the exact flags `scripts/build-adapter.sh` uses to build the test
  binary, syntax-only) — passed.
- `python3 -c "import ast; ast.parse(...)"` on
  `Engine/tests/metadata-loader.py` (AST parse only, no GI import, no
  execution, no `__pycache__` left behind) — passed.

NOT run here (root owns serialized native execution; the four native suites
and two pure suites were already reported green on the baseline): the
adapter build, the native conformance run of `glims-engine-tests` (including
`test_metadata_preservation_fixtures`), `swift test`, and the app smoke
tests. No runtime behavior of the new fixtures is claimed beyond the source
paths cited above.

## Gaps / uncertainties

- The oracle asserts GIMP's serialized XML (qualifiers as `lang=&quot;…&quot;`
  prefixes), not a raw XMP packet; a direct packet-level assertion would
  need GExiv2 GI access from the plug-in, which was deliberately not added.
- Bag-vs-Seq container identity after round trip is implied by the registry
  type on deserialize, not asserted from the oracle XML (the serialized form
  does not record the array type).
- The seed's own `gimp_image_set_metadata(..., TRUE)` pushes one undo step
  inside the load; the test captures the depth after open (`before`) and
  asserts only relative changes, so this does not affect the checks.
- `gimp_metadata_new()` (used by `gimp_metadata_deserialize`) opens GIMP's
  bundled minimal JPEG, so the seeded metadata also carries whatever EXIF
  that buffer holds; the assertions are on the fixture's own tags, which are
  unaffected.
