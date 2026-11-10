# XMP rights marker

Metadata offers Edit Rights Marker for the exact registered scalar
`Xmp.xmpRights.Marked`. Not specified removes the tag; Marked writes `True`;
Not marked writes `False`. Presence and false are distinct. Existing
noncanonical strings stay visible with Choose a value selected and cannot
become an implicit Boolean or removal.

The existing descriptor must match single-value XmpText before the action
opens. Each Apply reads fresh native policy and checks the captured presence,
document version and independent SET/REMOVE permissions. The editor uses the
document's counted metadata services. Native refusal keeps the draft for retry;
accepted changes use native Undo, exact no-ops add none, and stale/closing
callbacks cannot reopen the form or redirect it to a different document.

The form uses the schema's marker meaning and makes no inference about license
text or legal copyright status. Raw tag editing remains available separately.
No facade or native engine API is added; APIv1 remains163 slots.

Primary sources: Exiv2 0.28.9 `src/properties.cpp` declares this property as
Boolean/XmpText. GIMP3.2.8 metadata-tags.c/editor.c clear the tag for Unknown
and write exact `True`/`False`. The runtime descriptor reports scalar XmpText,
no multiple values and SET/REMOVE on all four supported engines.

The candidate passes984 units and19 actual-form checks on each engine.
Checks cover canonical/absent/unknown state, captured-document Apply, native
history/no-op, removal, Undo/Redo, XCF preservation, busy refusal/retry,
stale-document prevention and counted read/write closure. Existing metadata
forms, final release checks, review and CI remain under verification.
