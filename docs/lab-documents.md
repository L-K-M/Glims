# Native Lab documents

This is an engine foundation, not an enabled Lab editor. The Swift interface
still refuses these documents before showing a canvas; failed document
construction now closes the native image it was handed. Lab tools, creation
UI, recovery, conversion, layers, and PSD/TIFF interchange need subsequent
implementation and qualification.

## Authoritative storage

Facade slot 190 creates three native scalar planes in canonical L*, a*, b*
order and reports owned color mode 6. Private map mode 3 and encoding 2 require
exactly three unique nonzero UUIDs. The map's ink RGB fields are reserved and
must contain positive zero. Existing Multichannel/CMYK map encodings retain
their original meaning. Display names and native container order do not define
component identity.

U8 and U16 use the encoding in [lab-samples.md](lab-samples.md); float planes
hold physical signed Lab values. Initial white is `(255,128,128)`,
`(65535,32896,32896)`, or `(100,0,0)`, respectively. Same-format native buffer
writes preserve these bytes, without normalized grayscale conversion. D50 is
fixed; Lab has no user-supplied or persisted component ICC profile. All three
axes participate in the composite. Hidden-axis metadata is refused until an
axis-view contract exists.

Adoption captures the explicit mode for every component document. Each later
component call verifies that the persisted mode still matches it. Replacing a
Lab map with otherwise valid Multichannel metadata therefore cannot grant ink
editing access. Existing CMYK source-profile byte binding remains in force.

## Preview and permitted operations

The derived preview reads exact native samples in at most 256-pixel chunks,
decodes physical Lab, and uses the immutable transform described in
[lab-transform.md](lab-transform.md). Full-resolution linear RGB is generated
before mipmaps. No preview writes the authoritative channels. Nonfinite input
or unrepresentable RGB fails the public render; internal placeholder pixels
cannot count as a successful result. A later retry invalidates the failed
derived cache before reading repaired source values.

The native allowlist admits information, layers, color metadata, typed Lab axis
metadata, standard and
destination-profile rendering, XCF save/copy, history, and the existing neutral
selection/path/guide/grid reads. Every other component operation defaults to
denial. This includes ink edits, ink Levels/snapshots/identities, painting,
component/channel queries, selection mutations, duplication, and native CMYK
export. Ordinary RGB/PDB operations and cross-image sources remain protected.
Live stroke continuation checks both its destination and retained sources;
cleanup remains available even after metadata damage.

## Typed axis metadata

Slot 191 reads the three canonical axes with their current native handles,
document-scoped UUIDs, roles, selection membership and bounded UTF-8 display
names. Names and native channel order do not determine roles or identity.
The query reads no pixels and changes no selection, history or file identity;
it remains available during an admitted busy operation. Ordinary RGB, CMYK
and Multichannel images refuse this Lab-specific query.

The caller supplies a readable capacity word. Short output is untouched;
accepted output preserves that capacity and any extension tail while clearing
the known payload on every failure. Swift checks creation and metadata slots
independently, validates the complete returned record, and continues to load
older engines. This metadata does not yet enable Lab documents in the UI.

## Qualification

`scripts/test-lab-documents.py` runs four isolated fixtures against immutable
adapter producers: storage, admission, rendering, and mapped XCF roundtrip.
The render oracle checks default and linear destination-profile output,
single-pixel dirty reads, mipmaps, Undo/Redo, invalid samples, repair, and
source/preview destruction. The roundtrip fixture closes and finalizes the
original native image before reopening, then compares exact raw samples,
ordered UUIDs and mode at all three precisions, including signed zero,
subnormals and extreme finite float samples. Such extreme samples may be
preserved in a file even when their display transform correctly refuses.

These checks are separate from physical input, accessibility, performance on
large Lab documents, or Photoshop interchange qualification. No notarization
is requested or performed.

The axis-state fixture adds 6,288 checks per engine for canonical identities,
selection, renaming/reordering, UTF-8 truncation/refusal, short/extended output,
guard pages, damaged metadata, ordinary/ink refusal and unchanged native
state, including a dirty image with nonempty Undo and Redo stacks. All four
engines pass it, the expanded 304-check admission fixture,
general conformance and 26 Swift transport checks. Real 189- and 190-slot
producers each pass five compatibility checks. The six pure decoder tests,
1,560 full Swift tests and 130 Python preflight checks pass. Independent native
and Swift production reviews found no important issue. These results do not
qualify Lab editing or the installed application.
