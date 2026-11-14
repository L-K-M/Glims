# Layered Lab root identity

The appended `image_lab_layer_identity` API reads a logical root's durable
UUID from a strictly validated layered Lab image. The caller supplies both
the image ID and explicit runtime root ID. Hidden scalar planes and unrelated
layouts are refused. UUIDs are meaningful within their own document; a
matching UUID alone does not identify an unrelated document.

The output is size-versioned and may be unaligned. A null or short output is
untouched; accepted output keeps its caller-supplied size and extension bytes,
and clears the UUID on any failure. The read is allowed while the engine is
busy and changes no selection, pixels or history. This metadata operation does
not itself expose a fill or other edit.

The native public fixture checks distinct identities, invalid and hidden
targets, output boundaries, busy reads, Undo preservation, duplication,
reorder, and XCF save/reopen. A future queued edit must capture both document
and root identity and revalidate them before publication.
