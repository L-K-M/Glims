# LangAlt language-alternative read (engine-internal, read-only)

One bounded ENGINE-INTERNAL READ-ONLY reader for one registered XMP LangAlt
root property, on branch `feat/metadata-language-read` (base `08a3eb9`).
No facade slot, no `EngineAPI.h`/public-header/Swift/UI change, no writer,
no change to `Engine/metadata.c` or any generic-metadata behavior.

## Files

| File | Role |
|---|---|
| `Engine/metadata-language.h` | private header: owned pair `GlimsMetadataLanguagePair {char *language; char *text;}` and `GlimsStatus glims_metadata_language_read (GimpMetadata *, const char *root, GPtrArray **out, char **error)` |
| `Engine/metadata-language.c` | the reader (production, engine-only) |
| `Engine/tests/metadata-language-tests.c` | standalone harness, fixtures marshalled on the engine thread via one `glims_engine_call` |
| `scripts/test-metadata-language.py` | driver: `syntax` (all four `compile.rsp` sets), `build` (strict compile+link, never runs), `run` (owner's runtime decision) |
| `docs/metadata-language-read.md` | this document |

`GimpMetadata` is forward-declared in the private header; the native
GExiv2/GIMP headers are included only inside `Engine/`. The file is picked
up automatically by `build-adapter.sh`'s `Engine/*.c` loop; no build-script
change was needed.

## Contract

- Input `root` must be a plain registered XMP root property
  `Xmp.<group>.<property>` (no index/path/qualifier form, never another
  domain). The native registry decides registration
  (`gexiv2_metadata_try_get_tag_type`) and kind (`LangAlt`).
- The namespace URI comes from
  `gexiv2_metadata_try_get_xmp_namespace_for_tag(root, &error)`
  (transfer full). The CURRENT packet is generated with
  `gexiv2_metadata_try_generate_xmp_packet` (OMIT_PACKET_WRAPPER |
  USE_COMPACT_FORMAT | OMIT_ALL_FORMATTING, padding 0) — never the stored
  `try_get_xmp_packet`.
- A namespace-aware GMarkup parser inside `Engine/` resolves `xmlns`
  scopes by depth (prefix lookups walk the element stack top-down; `xml`
  is implicitly the XML namespace; never prefix-only matching). The target
  is the expanded root `{URI, property}`; only the simple shape
  `property / rdf:Alt / rdf:li` with exactly the `xml:lang` attribute and
  text-only content is admitted. Unsupported nesting, qualifiers,
  duplicate properties, mixed content, undeclared prefixes, duplicate
  case-folded language keys, embedded NUL, malformed UTF-8 and empty
  parsed texts are rejected. Language spelling is preserved exactly
  (case folding is used only for uniqueness); no BCP47 normalization is
  invented. Text is taken from the structured RDF with exact whitespace
  and unicode, no trimming.
- Bounds: packet <= 2 MiB, depth <= 32, pairs <= 256, aggregate text <=
  1 MiB; every parse/alloc/refusal path is cleaned up.
- Because the encoder OMITS empty native entries
  (E/src/xmp.cpp `printNode`/`AppendArrayItem` skip empty specs) and the
  zero-count native sentinel returns one empty string
  (G/gexiv2-metadata-xmp.cpp count==0 branch), the reader additionally
  requires a successful `gexiv2_metadata_try_get_tag_multiple` length to
  equal the parsed pair count, and requires the explicit-prefix strings
  rebuilt in the native writer's ACTUAL order (E/src/value.cpp
  `LangAltValue::write`: the key equal to `x-default` case-insensitively
  first, then every key not byte-equal to `x-default`, in map order —
  which is the packet's rdf:li order) to equal the native vector's
  strings element for element (full owned-string `strcmp`, not substring
  counts). The writer's case-sensitive skip of `x-default` would
  duplicate a case-variant key while the native count stays at the map
  size; the `k < n` guard refuses that quirk conservatively instead of
  normalizing it. This deliberately refuses ambiguous native splits
  (commas or literal `lang=` inside a later text) and hidden empties.
- Statuses: NULL required pointer or malformed root -> INVALID_ARGUMENT;
  unregistered or absent tag -> NOT_FOUND; wrong kind or any unsupported
  representation -> UNSUPPORTED; native read/parse errors -> FAILED with an
  owned message via the existing `glims_fail`/`strdup` conventions.
  `*out` is reset to NULL before every call and on every failure. On
  success `*out` is a `GPtrArray` of owned pairs (free function frees both
  strings and the pair; caller `g_ptr_array_unref`s). Reads only call
  `try_has_tag`, `try_generate_xmp_packet`, `try_get_tag_multiple` on the
  borrowed metadata — nothing is modified, installed or undone.

## Known limitation (documented, not a losslessness claim)

The native multiple-value vector is ambiguous for texts containing commas
or literal `lang=`/`, lang=` syntax in non-first entries, and the encoder
omits empty alternatives. The count-plus-exact-vector guard therefore
refuses such maps (and all-empty maps, and the zero-count sentinel) with
UNSUPPORTED rather than returning possibly-lossy pairs. States that are
not observable through the generated packet + native vector (e.g. an
opaque zero-count map) are refused, not guessed; this is a conservative
observable subset, not a universal losslessness claim. Duplicate
case-folded keys cannot be produced by the native case-insensitive map,
so that check is defensive.

## Checks actually run (this change)

- `python3 scripts/test-metadata-language.py syntax` — `-fsyntax-only`
  with `-Wall -Wextra -Werror=implicit-function-declaration` against the
  immutable Main producer `compile.rsp` of ALL FOUR engine sets
  (GIMP_3_0_8, GIMP_3_2_0, GIMP_3_2_8, master): all OK.
- `python3 scripts/test-metadata-language.py build --ref GIMP_3_2_8` —
  strict compile (`-Wall -Wextra -Werror` for the harness, producer flags
  for the reader) and link of reader + harness against the immutable
  producer objects (`obj/*.o`, `objects.rsp`, `link.rsp`): OK. The binary
  was NOT executed.
- Line budget: `Engine/metadata-language.c` 316 + `Engine/metadata-language.h`
  34 = 350 physical lines.

## Runtime scenarios — UNRUN here (owned by Root)

`scripts/test-metadata-language.py run --work <tmp>` starts one engine
per process with a throwaway HOME/XDG_CACHE_HOME/GIMP3_DIRECTORY and runs
`Engine/tests/metadata-language-tests.c`, which seeds fixtures through
the native multiple setter with explicit `lang="..."` prefixes and checks,
against independently hard-coded expected maps (native map order):
success for x-default/fr/de, missing default, XML characters/quotes/
unicode/whitespace/newlines and literal `lang=` in text when the exact
native vector represents them; refusals for missing tag, wrong kind,
indexed/path/non-XMP roots, NULL args, empty alternative in any position,
all-empty map, comma ambiguity in a later text, and the pair (257),
aggregate-text (1.2 MiB) and packet (3 MiB) bound overflows. Every read
and refusal is checked for unchanged generated packet, native vector,
metadata object pointer, undo/redo depth and dirty flag (read-only, no
undo). Native-error injection (DYLD_INSERT_LIBRARIES interpose, as in
scripts/test-metadata-error.py) is not wired into this driver yet and is
UNRUN. Nothing in this change was executed against an engine; compilation
is not acceptance.

## Source evidence

- G/gexiv2-0.14.7 `gexiv2-metadata-xmp.cpp`: `try_get_tag_multiple`
  LangAlt branch splits `it->toString()` on `, lang=` first, then bare
  commas (ambiguous); count==0 returns one empty string; the packet is
  generated by `try_generate_xmp_packet` from current xmpData.
- E/exiv2-0.28.9 `src/value.cpp` `LangAltValue::read/write`: case-
  insensitive map, default-first write, case-sensitive `x-default` skip;
  `src/xmp.cpp` encoder omits empty alternatives and appends rdf:li items
  in map order with `xml:lang` qualifiers.
- Admission policy: `/tmp/glims-completion/metadata-language-admission-audit.md`
  (audited Main d600117; UNRUN proposals there remain proposals).
