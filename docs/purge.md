# Edit > Purge

Edit > Purge frees memory. It is a submenu after the clipboard commands,
with four items and no shortcuts:

- **Undo** clears the active document's undo and redo history.
- **Clipboard** clears the engine's clipboard image, clipboard buffer and
  named buffers.
- **Histories** clears the undo and redo history of every open document.
- **All** clears the key document's history, every open document's history
  and the clipboard.

None of these can be undone, so every item first asks for confirmation
with "This cannot be undone." and **Purge** and **Cancel** buttons. The
sheet attaches to the key document window when there is one, and is
application-modal otherwise. Cancel changes nothing.

A purge never changes pixels. Purging an image whose history is already
empty succeeds and changes nothing. A dirty image stays dirty, as upstream
`gimp_image_undo_free` leaves it.

## Engine behavior

Facade slot 253, `edit_purge`, carries a `GlimsPurgeTarget` bitmask:
`GLIMS_PURGE_UNDO` (1), `GLIMS_PURGE_CLIPBOARD` (2) and
`GLIMS_PURGE_HISTORIES` (4). Zero or an unknown bit is
`GLIMS_STATUS_INVALID_ARGUMENT`. `UNDO` names an open image; 0 or an
unknown id is `GLIMS_STATUS_NOT_FOUND`. Without `UNDO` the image must be 0.

Every affected image is preflighted before anything is freed: an open undo
group, disabled undo, a running stroke, filter, plug-in or progress, or a
busy engine refuses `GLIMS_STATUS_BUSY` and leaves every history intact.
A purge is therefore never partial. A successful undo free reaches the app
as `GLIMS_EVENT_UNDO_CHANGED`, the same event undo and redo emit.

## Clipboard ownership

Glims's clipboard is the system pasteboard, not the engine's private
clipboard. Clearing the shared pasteboard would destroy another
application's copy, so **Purge > Clipboard** clears the system pasteboard
only while it still holds what Glims last wrote. `ClipboardImage` records
the general pasteboard's change count right after a successful write
(`ClipboardImage.ownedChangeCount`). `ClipboardImage.clipboardIsOwned`
compares that with the current change count. If another application has
written since, the pasteboard is left untouched and the result says "The
clipboard holds another application's data, so it was left unchanged."

The engine is always asked to purge its clipboard state too, so plug-in
buffers and named buffers are freed even when the system pasteboard is not
Glims's own.

## Menu validation

- **Undo** is disabled without an active document, on an adapter without
  slot 253, when the document's undo and redo histories are both empty, or
  while the document is closing or the engine is busy.
- **Histories** is disabled when no open document has any undo or redo
  step.
- **Clipboard** is disabled when the pasteboard does not hold Glims's own
  copy.
- **All** is enabled when any of the three is.

A disabled item's reason is its tool tip, as the adjustment items do.

## Recorder

Purge is not an image edit and changes no pixels, so it adds no Recorder
row. Purging undo history does not clear or alter a recording, and a
recording remains saveable and replayable. See [recorder.md](recorder.md).

## Swift state after a purge

Filter > Fade keys on the document's cached undo count and next undo name,
which the `UNDO_CHANGED` event refreshes, so a purge withdraws Fade from a
document whose newest step it cleared. Filter > Last Filter is app-wide and
is not tied to an undo step, so it is unchanged.
