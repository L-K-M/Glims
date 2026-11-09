# Typed capture date and time

Metadata's exact Exif.Photo.DateTimeOriginal tag offers Edit Date after
its current descriptor and values have loaded. The registered tag must be
single-value Ascii and writable. Unapplied text drafts stay in the generic
editor; the blank Add Tag placeholder can open the typed form without
first writing an empty value. Other tags retain their existing controls.

Six fields edit a fully specified camera-local Gregorian date and time.
The accepted subset is year1–9999, a real calendar day, hour0–23 and
minute/second0–59. Storage uses exact ASCII YYYY:MM:DD HH:MM:SS. The form
does not infer a timezone or use current time. OffsetTimeOriginal and
SubSecTimeOriginal are separate metadata fields and remain unchanged.

The exact original value remains visible. An absent or unsupported source
representation leaves fields blank until an explicit valid replacement;
opening, invalid input and Cancel never normalize the source. Apply sends
one captured string through the existing counted one-tag metadata writer.
An unchanged valid value skips the write. Native refusals retain the draft;
late callbacks cannot reopen closed UI. A document-version change blocks
stale Apply while retaining the fields until the editor is closed.

The model/policy suite passes16 focused tests and the full unit suite
passes931. On the pinned engine19 real-window checks pass for actual nested
sheets, calendar refusal, last-field Apply, captured documents, offset and
subsecond preservation, Undo/Redo, XCF, malformed sources, absent scalars,
native refusal/retry, a held counted write during document close and stale
Apply. The close fixture holds its queue until after close admission; it
cannot pass merely because a timeout released the write first. Other-engine,
legacy metadata-control and final self-contained bundle checks remain open.
Independent source review has no important production findings.
