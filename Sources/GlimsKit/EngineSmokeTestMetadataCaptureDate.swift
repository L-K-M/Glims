import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseMetadataCaptureDate(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let limit = Date().addingTimeInterval(15)
            while !condition() && Date() < limit { spin(0.01) }
        }
        func all<T: NSView>(_ root: NSView?, _ type: T.Type) -> [T] {
            guard let root else { return [] }
            return ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { all($0, type) }
        }
        func button(_ window: NSWindow, _ label: String) -> NSButton? {
            all(window.contentView, NSButton.self).first { $0.accessibilityLabel() == label }
        }
        let tag = MetadataSheetLogic.captureDateTag
        let original = "2020:01:02 03:04:05", replacement = "2000:02:29 12:34:56"
        let image = try session.newImage(width: 16, height: 16)
        let otherImage = try session.newImage(width: 12, height: 12)
        for (key, value) in [(tag, original), ("Exif.Photo.OffsetTimeOriginal", "+05:45"),
                             ("Exif.Photo.SubSecTimeOriginal", "1234"), ("Exif.Image.Artist", "Date fixture")] {
            try session.editMetadata(image, tag: key, .set, values: [value])
        }
        let document = try ImageDocument(session: session, image: image, name: "Capture Date A")
        let other = try ImageDocument(session: session, image: otherImage, name: "Capture Date B")
        documents.items += [document, other]
        let controller = DocumentWindowController(document: document), front = DocumentWindowController(document: other)
        controller.showWindow(nil); front.showWindow(nil)
        defer {
            for c in [controller, front] {
                c.metadataSheet?.invalidate()
                if let sheet = c.window?.attachedSheet { c.window?.endSheet(sheet) }
                c.window?.orderOut(nil)
                var stopped = false; c.canvas.stopRendering { stopped = true }; wait { stopped }
            }
            for doc in [document, other] where !doc.isClosing {
                var closed = false; doc.closeImageWhenDrained { closed = true }; wait { closed }
            }
            documents.items.removeAll { $0 === document || $0 === other }
        }
        func settle() { document.inputQueue.sync {}; wait { document.pendingWork == 0 }; spin(0.03) }
        controller.showMetadata(nil)
        guard let meta = controller.metadataSheet,
              let table = all(meta.panel.contentView, NSTableView.self).first(where: { $0.accessibilityLabel() == "Metadata tag list" }),
              let launch = button(meta.panel, "Edit capture date and time") else {
            return check(false, "Metadata exposes the typed capture-date action")
        }
        func selectDate() {
            wait {
                (0..<meta.numberOfRows(in: table)).contains {
                    meta.tableView(table, objectValueFor: nil, row: $0) as? String == tag
                }
            }
            if let row = (0..<meta.numberOfRows(in: table)).first(where: {
                meta.tableView(table, objectValueFor: nil, row: $0) as? String == tag
            }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                meta.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
            }
            wait { launch.isEnabled }
        }
        func open() -> MetadataCaptureDateEditor? {
            wait { launch.isEnabled }; launch.performClick(nil)
            wait { meta.captureDateEditor != nil }
            return meta.captureDateEditor
        }
        func set(_ editor: MetadataCaptureDateEditor, year: String = "2000") {
            editor.yearField.stringValue = year; editor.monthField.stringValue = "2"
            editor.dayField.stringValue = "29"; editor.hourField.stringValue = "12"
            editor.minuteField.stringValue = "34"; editor.secondField.stringValue = "56"
        }
        selectDate()
        let baseline = try session.undoInfo(image).undoCount
        guard let editor = open() else { return check(false, "the actual typed date action opens") }
        check(editor.window?.sheetParent === meta.panel && editor.sourceText == original && editor.yearField.stringValue == "2020",
              "the typed date sheet keeps its captured owner and exact source text")
        set(editor, year: "1900"); editor.apply(nil); settle()
        check(editor.lastError != nil && !editor.isWriting && editor.yearField.stringValue == "1900"
              && (try? session.metadataValues(image, tag: tag)) == [original]
              && (try? session.undoInfo(image).undoCount) == baseline,
              "an invalid leap day keeps its draft and leaves metadata/history unchanged")
        set(editor)
        editor.secondField.stringValue = "55"
        editor.window?.makeKeyAndOrderFront(nil)
        editor.window?.makeFirstResponder(editor.secondField)
        if let fieldEditor = editor.secondField.currentEditor() { fieldEditor.string = "56" }
        else { check(false, "the capture-date field editor accepts a pending last edit") }
        front.window?.makeKeyAndOrderFront(nil)
        editor.apply(nil)
        wait { meta.captureDateEditor == nil }; settle()
        check(try session.metadataValues(image, tag: tag) == [replacement]
              && session.metadataValues(otherImage, tag: tag).isEmpty,
              "valid Apply changes only the captured document")
        check(try session.undoInfo(image).undoCount == baseline + 1, "typed date Apply adds one native Undo")
        check(try session.metadataValues(image, tag: "Exif.Photo.OffsetTimeOriginal") == ["+05:45"]
              && session.metadataValues(image, tag: "Exif.Photo.SubSecTimeOriginal") == ["1234"]
              && session.metadataValues(image, tag: "Exif.Image.Artist") == ["Date fixture"],
              "offset, subseconds and unrelated metadata remain exact")
        selectDate()
        guard let unchanged = open() else { return check(false, "an applied capture date reopens") }
        unchanged.apply(nil); wait { meta.captureDateEditor == nil }; settle()
        check(try session.undoInfo(image).undoCount == baseline + 1, "untouched typed Apply adds no history")
        selectDate()
        guard let cancelled = open() else { return check(false, "the typed date can reopen for Cancel") }
        set(cancelled, year: "2024"); cancelled.cancel(nil); settle()
        check(try session.metadataValues(image, tag: tag) == [replacement]
              && session.undoInfo(image).undoCount == baseline + 1, "Cancel preserves the stored date and Undo")
        try session.undo(image); try document.reload()
        check(try session.metadataValues(image, tag: tag) == [original], "one Undo restores the exact original capture date")
        try session.redo(image); try document.reload()
        check(try session.metadataValues(image, tag: tag) == [replacement], "Redo restores the typed capture date")
        let path = work.appendingPathComponent("capture-date.xcf")
        try session.save(image, to: path.path)
        let reopened = try session.openImage(path: path.path)
        check(try session.metadataValues(reopened, tag: tag) == [replacement]
              && session.metadataValues(reopened, tag: "Exif.Photo.OffsetTimeOriginal") == ["+05:45"]
              && session.metadataValues(reopened, tag: "Exif.Photo.SubSecTimeOriginal") == ["1234"],
              "XCF preserves the date, independent offset and subseconds")
        try session.closeImage(reopened)
        // ASCII metadata can contain a non-calendar representation. Opening and
        // cancelling the typed subset must retain it, rather than repairing it.
        let malformed = "unknown capture time"
        try session.editMetadata(image, tag: tag, .set, values: [malformed]); try document.reload()
        meta.documentStateDidChange(); settle(); selectDate()
        let malformedHistory = try session.undoInfo(image).undoCount
        guard let invalid = open() else { return check(false, "an existing unknown capture date remains viewable") }
        check(invalid.sourceText == malformed && invalid.yearField.stringValue.isEmpty && invalid.secondField.stringValue.isEmpty,
              "an unsupported existing representation stays visible without invented fields")
        invalid.apply(nil); settle()
        check(invalid.lastError != nil && (try? session.metadataValues(image, tag: tag)) == [malformed]
              && (try? session.undoInfo(image).undoCount) == malformedHistory,
              "untouched malformed source never becomes an implicit replacement")
        invalid.cancel(nil); settle()
        // A standalone captured editor also supports absent registered scalars;
        // the parent gate separately proves the Add Tag placeholder route.
        guard let absent = MetadataCaptureDateEditor(document: other, values: []) else {
            return check(false, "a registered absent capture date can be edited")
        }
        set(absent); absent.apply(nil)
        wait { absent.isInvalidated && other.pendingWork == 0 }
        check(try session.metadataValues(otherImage, tag: tag) == [replacement], "an absent scalar gains one explicit complete date")
        guard let busy = MetadataCaptureDateEditor(document: other, values: [replacement]),
              let otherLayer = other.activeLayer else { return check(false, "the refusal fixture opens") }
        set(busy, year: "2024")
        let beforeRefusal = try session.undoInfo(otherImage).undoCount
        let heldFilter = try session.beginFilter(image: otherImage, drawable: otherLayer, operation: "gegl:gaussian-blur")
        busy.apply(nil); wait { !busy.isWriting && other.pendingWork == 0 }
        check(busy.lastError != nil && busy.yearField.stringValue == "2024"
              && (try? session.metadataValues(otherImage, tag: tag)) == [replacement]
              && (try? session.undoInfo(otherImage).undoCount) == beforeRefusal,
              "a native refusal keeps the date draft and leaves metadata/history unchanged")
        try session.abortFilter(heldFilter)
        busy.apply(nil); wait { busy.isInvalidated && other.pendingWork == 0 }
        check(try session.metadataValues(otherImage, tag: tag) == ["2024:02:29 12:34:56"],
              "a refused capture-date edit can retry after the native operation ends")
        guard let late = MetadataCaptureDateEditor(document: other, values: ["2024:02:29 12:34:56"]) else {
            return check(false, "the late completion fixture opens")
        }
        set(late)
        let barrier = DispatchSemaphore(value: 0)
        other.inputQueue.async { barrier.wait() }
        late.apply(nil)
        check(late.isWriting && other.pendingWork > 0, "an admitted date write is counted before queued work starts")
        late.invalidate()
        var renderStopped = false; front.canvas.stopRendering { renderStopped = true }; wait { renderStopped }
        front.window?.orderOut(nil)
        var otherClosed = false; other.closeImageWhenDrained { otherClosed = true }
        check(!otherClosed && other.pendingWork > 0, "document close waits while its admitted date write is held")
        barrier.signal(); wait { otherClosed && other.pendingWork == 0 }
        check(otherClosed && late.isInvalidated && late.window?.isVisible != true && other.pendingWork == 0,
              "closing a date editor and document drains its admitted write without reopening UI")
        selectDate()
        guard let stale = open() else { return check(false, "the date form opens for document-change guarding") }
        set(stale, year: "2024")
        var changed = false
        document.editMetadata("Exif.Image.Artist", .set, values: ["Changed elsewhere"]) { _ in changed = true }
        wait { changed }; settle(); stale.documentStateDidChange(); stale.apply(nil)
        check(stale.lastError?.contains("document changed") == true && stale.yearField.stringValue == "2024"
              && (try? session.metadataValues(image, tag: tag)) == [malformed],
              "a changed document blocks stale Apply while preserving the local draft")
        stale.cancel(nil); settle()
    }
}
