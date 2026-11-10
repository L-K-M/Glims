# XCF effect state

The adapter supplements native XCF for two fields that the supported native
engines do not retain: Curves' five actual HDR bypass flags, and drawable
filters' blend space, composite space and composite mode. It never derives
bypass from a diagonal graph. The unchanged native engine still writes and
reads the actual image, source pixels, layers and operation configurations.

This integration candidate is under review. Its initial literal HDR regression
fails ten assertions per engine before the fix: both Save and Save Copy
reopen with identity flags11111 becoming00000, explicit composite values
becoming AUTO, and rendered(-0.5,0.5,1.5,1.25) becoming(0,0.5,1,1).
The corrected implementation passes121 focused checks on each of all four
engines. The general conformance suite passes1,917 checks per3.2/master
engine and1,703 on3.0.8. Final release checks and CI are still pending.

The private `glims-effect-state-v1` image parasite is regenerated from current
live effect state only for an XCF Save or Save Copy. It is persistent and
non-undoable. Both write success and write failure restore the exact previous
live parasite, including absence. Export does not add it. After loading,
validated supplements are restored before document adoption, without adding
Undo or dirtying the document, then removed from live image metadata. Edits,
Undo/Redo, duplicate/remove/reorder and subsequent saves therefore use current
native state rather than an old cached supplement.

The payload is a bounded, versioned key file: at most1MiB and4096 records.
It contains independent fingerprints, drawable tattoos/stack addresses,
validated native enum nick strings and five-bit Curves identity masks. It
contains no pointers, native struct layouts or raw enum integers. The parser
rejects repeated groups/keys, unknown keys/versions, overflow, malformed
hashes, invalid masks and duplicate target addresses. Native enum membership
and complete target correspondence are checked before the first mutation.
The fingerprints normalize native default-title name reclassification and
the historical Overlay/Softlight paint-mode alias.

Correspondence uses the image dimensions/base type/precision, ordered native
drawables and their tattoos/geometry, committed stack order/count, operation,
persisted custom name/active state/float opacity/paint mode/clip/region, and separately
normalized native operation configuration. Normalization uses an owned
same-type configuration and native serialization/deserialization; it never
sets source properties. Positional indexes are excluded from content hashes
so indistinguishable effects with conflicting supplemental state are
rejected before saving or restoring. Changing an effect name disambiguates that case.

Files without a supplement retain native loading behavior. A malformed,
unknown or detectably stale supplement refuses loading with an error; it
never restores state to a guessed current selection. A Glims supplement is
an extension that foreign editors do not implement. If a foreign editor
retains the parasite while editing only a native-unserialized field and
leaves the complete surviving representation identical, its intent cannot
be distinguished from the saved Glims state. The fingerprints do not prove
freshness in that case. Arbitrary foreign XCF files cannot recover values
that their writer already discarded.

The first implementation admits native point-operation configurations.
Ordinary GEGL effects with AUTO fields continue through native XCF. An
unsupported non-AUTO configuration refuses saving before mutation rather
than silently losing those fields. Generic GEGL configurations, effect
masks and native representations outside supported admission remain explicit
completion work. In particular the native Curve `n-samples` GParamSpec is
fixed at256 on all four engines; source objects changed directly through Core
to larger tables cannot round-trip through native serde. They must be refused
until an exact representation extension is implemented. Graph/tool filters
that native XCF cannot write are also refused. These restrictions are
separate from preserving the five HDR bypass flags.

Native references: pinned GIMP3.2.8 commit
7addd2b77efb798bbdc4dbf2b082e786a48478ced,
`app/core/gimpcurve.c` serialization/deserialization and `n-samples` property,
`app/operations/gimpcurvesconfig.c` whole-config serialization,
`app/xcf/xcf-save.c:xcf_save_effect_props/xcf_save_prop`, and
`app/xcf/xcf-load.c:xcf_load_effect_props`. The same omissions and AUTO
normalization were inspected in3.0.8,3.2.0 and master. No upstream source is
modified. The facade stays APIv1 with163 slots.

Checks: the standalone75-assertion parser suite independently found two
raw duplicate-empty-group cases that GKeyFile merges; the parser now rejects
both. Native tests exercise actual HDR output and source bytes, both write
purposes/fresh opens, clean loaded history, failed-write carrier rollback,
unknown enums/versions and stale fingerprints before mutation. The121 native checks also cover current-state re-saves after edit, Undo
and Redo, the native name/paint aliases, explicit mask/graph/non-native-table
refusals, and ambiguous duplicate records before either target changes.
The reviewed integration revision and final bundled checks remain pending.
