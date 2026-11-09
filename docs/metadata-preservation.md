# Complete metadata inventory and detached language edits

GExiv2 0.14.7 omits zero-count EXIF, IPTC and XMP entries from its public tag
lists. Exiv2 0.28.9 also omits empty LangAlt maps from generated XMP packets.
A metadata duplicate can therefore lose a field while both public views compare
equal. The regression imports a legal raw XMP sidecar with a valid French title
and an empty dc:rights alternative map. Against the earlier producer, preparation
returns a copy missing that entry, and generic metadata editing replaces the
image's metadata with the lossy copy. The regression fails three assertions.

The adapter now checks the complete native inventory before trusting a copy.
A small C++ bridge borrows the existing Exiv2 metadata collections, counts actual
XMP entries and counts zero-count entries across all three domains. A hidden
entry refuses replacement; the original object and its contents remain intact.
The generic metadata writer uses this check too. Repeated positive IPTC entries
remain allowed because the guard counts zero entries rather than comparing the
number of IPTC records with the public list's deduplicated keys.

Only Engine accesses this dependency layout. The unmodified upstream private
GExiv2 header is included with its license, source link and fingerprint. Both
compile-time and running versions must match GExiv2 0.14.7 and Exiv2 0.28.9;
runtime checks precede private-field access. Unknown running versions refuse,
and header upgrades fail compilation with a compatibility-review message. This
supports the pinned, verified dependency producer; it does not certify arbitrary
modified binaries reporting the same version. No upstream source is patched,
no libgimp is loaded and no native layout crosses the facade.

The build derives C++ include/target flags from the engine, replaces its C-only
flags and Objective-C language selection with C++17, and links the installed
Exiv2 library beside the derived GExiv2 dependency. The adapter still exports
only glims_engine_get_api. Exiv2 was already a bundled transitive dependency.

An engine-internal preparation function edits one EXISTING exact language key
on a detached copy. It reads every admitted LangAlt map before duplication,
checks all maps and complete metadata through copying, verifies native image-fact
normalization is already stable, applies one explicit-prefix native string
assignment, verifies a roundtrip, then restores the old text on a disposable copy
to compare all unrelated metadata against the original. An exact no-op returns
OK with no replacement. Unregistered, nested, ambiguous or empty representations
refuse conservatively. This function never installs metadata, pushes Undo or
authorizes mutation. A future caller still needs readiness and one native setter;
no public language-writing slot or UI is enabled by this change.

The normalization helper applies dimensions, component bits, resolution/unit and
colorspace to a caller-owned detached copy. It refuses the attached-object alias.
Its OK result means only that native requests completed, not that fidelity was
proved; independent whole-metadata/map checks remain mandatory.

Validation on all four supported engines:

- Existing native conformance: 1,917 checks on 3.2.8, 3.2.0 and master; 1,703 on 3.0.8.
- 27 preparation/refusal/preservation checks, including real hidden empty maps,
  zero-count EXIF/IPTC, unchanged facts/history and the existing generic writer.
- 9 inventory/version-refusal checks, including wrong-version unrelated objects
  and 2 complete entries versus 1 filtered entry on the legal empty-map fixture.
- 124 normalization checks: all six component types, native Adobe and another
  explicit RGB profile, a separate native-setter oracle, idempotence and unchanged
  source metadata/history. The helper's production body is unchanged afterward.

All 838 app unit tests and 14 script tests pass. Runtime uses fatal GLib criticals
and isolated absolute home/cache/user directories. Relative home paths exposed a
3.2.0 initialization assertion; the shared test driver now canonicalizes them.
Raw empty-map import emits native conversion warnings, and master has its known
missing cached-XML cleanup diagnostic; neither is a GLib critical or test failure.

Independent source review caught the original enumeration hole. The corrected
inventory bridge/build changes passed a Vibe Large4 review and a separate source
addendum for all-domain zero counting; no important issue remained within the
pinned dependency ABI. Full packaged-app validation and hosted CI are pending.

Single-language public editing (slot141) uses the sealed preparation path,
then the native image setter as one metadata Undo operation. Exact no-ops
return before readiness checks. Both this writer and the generic slot126
refuse actual changes with BUSY if native Undo is frozen or disabled: a
plug-in can otherwise leave that state behind after it returns. The guard
does not thaw or enable Undo, which could destroy existing history or break
a nested native operation. A direct native fixture reproduces the original
change-without-Undo behavior and checks both freeze and disable refusals,
no-op success, the original object/serialized values, dirty state and history.
