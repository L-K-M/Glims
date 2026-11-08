# Metadata preservation fixtures

The conformance suite installs `Engine/tests/metadata-loader.py` in its
private plug-in directory before starting the engine. It registers a
`.gmeta` loader and a small-image metadata oracle. These are test fixtures,
never bundled app resources or production procedures.

The loader constructs native metadata XML with distinct x-default and
fr-FR language alternatives, a Bag, a Seq, EXIF Artist and repeated IPTC
keywords. A second fixture contains exactly 1,001 DocumentAncestors entries.

The public metadata serializer caps that array at 1,000 entries. Private
metadata procedures also cannot be obtained through plug-in procedure
lookup. The fixture therefore writes a minimal version-11 XCF containing
a raw `gimp-image-metadata` parasite and loads it through the native XCF
loader. The fixture then adds its ordinary pixel layer. No metadata
serialization occurs before the native parser sees the original XML.

The file format constants follow `app/xcf/xcf-private.h`, `xcf-save.c`,
`xcf-load.c` and `libgimpbase/gimpbaseenums.h`: RGB, 8-bit non-linear,
64-bit empty layer/channel offset tables and the persistent metadata
parasite property. This creates test data only; it does not modify upstream
sources. The loader deliberately registers no MIME type, preventing
LoadProcedure's automatic metadata finisher from replacing its seeded
metadata with data from the empty `.gmeta` marker file.

The small-fixture oracle uses the public metadata getter and serializer.
Its XML retains the language keys, so checking only translated text cannot
hide lost qualifiers. Bag and Seq values, Artist and undo depth are checked
separately. The tests cover an unrelated Artist edit, Undo, Redo and XCF
save/reopen. The oracle is never used on the ancestor fixture: facade
reads first establish all 1,001 original values, an unrelated edit must
refuse without an undo step, and every original value must remain intact.

Initial runtime attempts exposed two fixture errors: private PDB lookup
returned no procedure, and a MIME type caused automatic metadata import
to overwrite the seed. Both were corrected. With the real fixtures active,
the guard correctly refused the 1,001-entry image, but also refused the
small qualified image because XMP property and namespace-attribute order
changed during a native duplicate. Production comparison now uses the
structural packet representation described in `image-metadata.md`.

C syntax and Python AST checks passed in the helper. Root owns native
runtime verification of the final fixture and comparison. The PR records
its exact engine matrix; compilation alone is not preservation evidence.

The oracle checks qualified XML rather than raw XMP bytes. It proves both
language keys and texts survive; it does not independently assert Bag vs
Seq type from that XML. Native packet comparison additionally retains
container element names and array order. All created facade images close
before engine shutdown; the loader does not open desktop windows.

Final root verification: all four native suites pass after the fixture and
structural comparison changes: 1,876 / 1,662 / 1,876 / 1,876 checks for
3.2.8 / 3.0.8 / 3.2.0 / master. Seven Swift facade/input tests also pass.
The production XML comparator is isolated in `Engine/metadata-xmp.c` so
`python3 scripts/test-metadata-xmp.py` tests the real implementation without
an engine. Two CDATA assertions reproduced ignored text before enabling
GMarkup's CDATA-as-text flag; all 14 structural checks then pass.

The first structural native run had two unrelated link-reopen assertions
fail. A status/error diagnostic was added to that existing fixture. The
subsequent pinned run and final four-engine matrix pass; that transient
failure has no established root cause and is not claimed fixed.
