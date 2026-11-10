import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseMetadataRights(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let limit = Date().addingTimeInterval(15)
            while !condition() && Date() < limit { spin(0.01) }
        }
        func all<T: NSView>(_ root: NSView?, _ type: T.Type) -> [T] {
            guard let root else { return [] }
            return ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { all($0, type) }
        }
        func button(_ window: NSWindow?, _ label: String) -> NSButton? {
            all(window?.contentView, NSButton.self).first { $0.accessibilityLabel() == label }
        }
        func choose(_ editor: MetadataRightsEditor, _ value: MetadataRightsValue) {
            editor.popup.selectItem(withTitle: value.title)
            if let action = editor.popup.action { NSApp.sendAction(action, to: editor.popup.target, from: editor.popup) }
        }
        let tag = MetadataSheetLogic.rightsMarkerTag
        let image = try session.newImage(width: 16, height: 16), otherImage = try session.newImage(width: 12, height: 12)
        try session.editMetadata(image, tag: tag, .set, values: ["False"])
        try session.editMetadata(image, tag: "Exif.Image.Artist", .set, values: ["Rights fixture"])
        let document = try ImageDocument(session: session, image: image, name: "Rights A")
        let other = try ImageDocument(session: session, image: otherImage, name: "Rights B")
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
              let domain = all(meta.panel.contentView, NSPopUpButton.self).first(where: { $0.accessibilityLabel() == "Metadata domain" }),
              let table = all(meta.panel.contentView, NSTableView.self).first(where: { $0.accessibilityLabel() == "Metadata tag list" }),
              let launch = button(meta.panel, "Edit XMP rights marker") else {
            return check(false, "Metadata exposes the typed rights-marker action")
        }
        domain.selectItem(withTitle: "XMP")
        if let action = domain.action { NSApp.sendAction(action, to: domain.target, from: domain) }
        func selectRights() {
            wait { (0..<meta.numberOfRows(in: table)).contains { meta.tableView(table, objectValueFor: nil, row: $0) as? String == tag } }
            if let row = (0..<meta.numberOfRows(in: table)).first(where: { meta.tableView(table, objectValueFor: nil, row: $0) as? String == tag }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                meta.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
            }
            wait { launch.isEnabled }
        }
        func open() -> MetadataRightsEditor? {
            wait { launch.isEnabled }; launch.performClick(nil); wait { meta.rightsEditor != nil }
            if let editor = meta.rightsEditor { wait { !editor.isReading } }
            return meta.rightsEditor
        }
        selectRights()
        let baseline = try session.undoInfo(image).undoCount
        guard let editor = open() else { return check(false, "the actual rights action opens its owned form") }
        check(editor.window?.sheetParent === meta.panel && editor.sourceText == "False" && editor.popup.titleOfSelectedItem == MetadataRightsValue.unmarked.title,
              "the actual form shows False distinctly from an absent marker")
        choose(editor, .marked); front.window?.makeKeyAndOrderFront(nil); editor.apply(nil)
        wait { editor.isInvalidated }; settle()
        check(try session.metadataValues(image, tag: tag) == ["True"] && session.metadataValues(otherImage, tag: tag).isEmpty,
              "rights Apply edits only its captured document")
        check(try session.undoInfo(image).undoCount == baseline + 1 && session.metadataValues(image, tag: "Exif.Image.Artist") == ["Rights fixture"],
              "rights Apply adds one Undo and preserves unrelated metadata")
        selectRights(); guard let unchanged = open() else { return check(false, "the applied marker can reopen") }
        unchanged.apply(nil); wait { unchanged.isInvalidated }; settle()
        check(try session.undoInfo(image).undoCount == baseline + 1, "unchanged marker Apply creates no native history")
        try session.undo(image); try document.reload()
        check(try session.metadataValues(image, tag: tag) == ["False"], "Undo restores False without removing the marker")
        try session.redo(image); try document.reload()
        check(try session.metadataValues(image, tag: tag) == ["True"], "Redo restores the exact True marker")
        selectRights(); guard let remove = open() else { return check(false, "the marker opens for explicit removal") }
        choose(remove, .unspecified); remove.apply(nil); wait { remove.isInvalidated }; settle()
        check(try session.metadataValues(image, tag: tag).isEmpty, "Not specified removes the marker rather than writing False")
        let absentUndo = try session.undoInfo(image).undoCount
        guard let absent = MetadataRightsEditor(document: document, values: []) else { return check(false, "an absent marker opens") }
        absent.present(on: meta.panel); wait { !absent.isReading }; absent.apply(nil); wait { absent.isInvalidated }; settle()
        check(try session.undoInfo(image).undoCount == absentUndo && session.metadataValues(image, tag: tag).isEmpty,
              "removing an absent marker is a native no-op")
        try session.editMetadata(image, tag: tag, .set, values: ["unknown original marker"]); try document.reload(); meta.documentStateDidChange(); settle(); selectRights()
        let unknownUndo = try session.undoInfo(image).undoCount
        guard let unknown = open() else { return check(false, "a noncanonical existing marker remains viewable") }
        check(unknown.sourceText == "unknown original marker" && unknown.popup.titleOfSelectedItem == "Choose a value",
              "unknown raw metadata stays exact with no implicit Boolean choice")
        unknown.apply(nil); settle()
        check(!unknown.isInvalidated && (try? session.metadataValues(image, tag: tag)) == ["unknown original marker"] && (try? session.undoInfo(image).undoCount) == unknownUndo,
              "untouched unknown marker cannot become an implicit removal or false value")
        unknown.cancel(nil); settle()
        guard let busy = MetadataRightsEditor(document: document, values: ["unknown original marker"]), let layer = document.activeLayer else { return check(false, "the rights refusal fixture opens") }
        busy.present(on: meta.panel); wait { !busy.isReading }; choose(busy, .marked)
        let held = try session.beginFilter(image: image, drawable: layer, operation: "gegl:gaussian-blur")
        busy.apply(nil); wait { !busy.isReading && !busy.isWriting && document.pendingWork == 0 }
        check(busy.lastError != nil && busy.popup.titleOfSelectedItem == MetadataRightsValue.marked.title && (try? session.metadataValues(image, tag: tag)) == ["unknown original marker"] && (try? session.undoInfo(image).undoCount) == unknownUndo,
              "native refusal preserves the selected rights draft and original metadata/history")
        try session.abortFilter(held); busy.apply(nil); wait { busy.isInvalidated }; settle()
        check(try session.metadataValues(image, tag: tag) == ["True"], "a refused rights write can retry after native work ends")
        let file = work.appendingPathComponent("rights-marker.xcf"); try session.save(image, to: file.path)
        let reopened = try session.openImage(path: file.path)
        check(try session.metadataValues(reopened, tag: tag) == ["True"] && session.metadataValues(reopened, tag: "Exif.Image.Artist") == ["Rights fixture"],
              "XCF preserves the typed marker and independent metadata")
        try session.closeImage(reopened)
        guard let stale = MetadataRightsEditor(document: document, values: ["True"]) else { return check(false, "the changed-document fixture opens") }
        stale.present(on: meta.panel); wait { !stale.isReading }; choose(stale, .unmarked)
        var changed = false; document.editMetadata("Exif.Image.Artist", .set, values: ["Elsewhere"]) { _ in changed = true }
        wait { changed }; settle(); stale.documentStateDidChange(); stale.apply(nil)
        check(stale.lastError?.contains("document changed") == true && stale.popup.titleOfSelectedItem == MetadataRightsValue.unmarked.title && (try? session.metadataValues(image, tag: tag)) == ["True"],
              "a changed document refuses stale rights Apply and keeps its draft")
        stale.cancel(nil)
        let readBarrier = DispatchSemaphore(value: 0)
        document.inputQueue.async { readBarrier.wait() }
        guard let cancelledRead = MetadataRightsEditor(document: document, values: ["True"]) else {
            readBarrier.signal(); return check(false, "the pending rights read fixture opens")
        }
        cancelledRead.present(on: meta.panel)
        check(cancelledRead.isReading && document.pendingWork > 0,
              "the rights descriptor read is counted before queued work starts")
        cancelledRead.cancel(nil); readBarrier.signal(); settle()
        check(cancelledRead.isInvalidated && cancelledRead.window?.isVisible != true
              && (try? session.metadataValues(image, tag: tag)) == ["True"],
              "cancelling a pending descriptor read prevents late UI delivery and preserves metadata")

        guard let late = MetadataRightsEditor(document: other, values: []), let parent = front.window else {
            return check(false, "the held rights-write fixture opens")
        }
        late.present(on: parent); wait { !late.isReading }; choose(late, .marked)
        let writeBarrier = DispatchSemaphore(value: 0)
        late.apply(nil)
        // Apply reads policy first. Hold the input queue after that read so
        // its main-thread completion can admit a write behind this barrier.
        other.inputQueue.async { writeBarrier.wait() }
        wait { late.isWriting }
        check(late.isWriting && other.pendingWork > 0,
              "the rights write remains counted after its fresh descriptor read")
        late.invalidate()
        var otherClosed = false; other.closeImageWhenDrained { otherClosed = true }
        check(!otherClosed && other.pendingWork > 0, "document close waits for its admitted rights write")
        writeBarrier.signal(); wait { otherClosed && other.pendingWork == 0 }
        check(otherClosed && late.isInvalidated && late.window?.isVisible != true,
              "rights editor and document closure drain accepted work without reopening UI")
    }
}
