# Metadata editing controls

Image ▸ Metadata… opens a sheet owned by its document window. EXIF, IPTC
and XMP tag lists are read through the counted document queue and filtered
locally. Values have individual rows and a multiline editor. Apply commits
the captured ordered array; Remove Tag is an explicit separate operation.
Closing the sheet discards only its unapplied draft.

Reads disable draft editing until the captured values arrive. Apply freezes
tag/domain selection. Generation checks discard stale callbacks, and clean
values refresh after Undo/Redo even when the selected tag is unchanged.
Successful edits collect info and history on the worker before updating the
main-actor cache. Validation uses cached state; metadata jobs remain counted
until close drains them.

Add Tag validates registration with a read, then creates a local draft.
No empty native value is written before the user enters text and applies.
Normalization-protected tags are read-only. Other unsupported formats show
the native refusal. Text that can have different versions for different
languages is shown for reading only and cannot be safely changed yet;
Glims also cannot yet choose a new XMP container type.

The editor preserves duplicate, multiline and empty draft rows as separate
values. The native backend verifies exact representability before attaching
a prepared replacement. On the current stack an empty IPTC list entry is
Unsupported: the native value, history and draft stay intact. Nonempty
multiline/duplicate lists and single-value replacements work. An empty
array is refused locally with the instruction to use Remove Tag.

The real-controls regression first reproduced stale same-tag Undo values,
late read results overwriting drafts, navigation during Apply, and native
value-list losses. The fixes pass the focused controls run on every engine,
including exact arrays, refused empty members, local new-tag drafts, Undo,
Redo, XCF save/reopen, two-document capture, close drain and late callbacks.
All 612 unit tests pass. The broader integrated app run remains pending.
Independent source review found no important remaining issue; Add Tag's
selection of an existing tag hidden by a filter remains a minor UI edge.
