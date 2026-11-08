import AppKit
import RigiUI

/// `GLIMS_SMOKE_CASE=metadata-controls`: drives Image ▸ Metadata… end to
/// end through the real menu item, the per-document sheet and its
/// controls, with the actual queued document work — selected tag/value
/// editing, two-document capture, no-op undo, a native refusal without a
/// false update, multiline/duplicate/empty values preserved exactly,
/// queued completion/close drain with late results, and undo/save/reopen
/// for a backend-supported tag. Lookups go through accessibility labels;
/// the recursive helper descends even when the root itself matches.
/// Controlled semaphore gates on the input queue are released on every
/// path; waits are condition-based, never fixed sleeps as proof.
@MainActor
extension EngineSmokeTest {
    static func exerciseMetadataControls(_ session: EngineSession, work: URL,
                                         documents: DocumentList) throws {
        // Recursive view search that recurses into children EVEN WHEN THE
        // ROOT ITSELF MATCHES the type (an NSStackView root must not hide
        // a nested match of the same class).
        func allViews<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
            guard let root else { return [] }
            var found: [T] = []
            if let match = root as? T { found.append(match) }
            for child in root.subviews { found += allViews(child, as: type) }
            return found
        }
        func wait(_ condition: @escaping () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func button(_ sheet: NSWindow?, _ label: String) -> NSButton? {
            allViews(sheet?.contentView, as: NSButton.self).first { $0.accessibilityLabel() == label }
        }
        func editableField(_ sheet: NSWindow?, _ label: String) -> NSTextField? {
            allViews(sheet?.contentView, as: NSTextField.self)
                .first { $0.isEditable && $0.accessibilityLabel() == label }
        }
        func label(_ sheet: NSWindow?, _ text: String) -> NSTextField? {
            allViews(sheet?.contentView, as: NSTextField.self)
                .first { !$0.isEditable && $0.accessibilityLabel() == text }
        }
        func table(_ sheet: NSWindow?, _ text: String) -> NSTableView? {
            allViews(sheet?.contentView, as: NSTableView.self).first { $0.accessibilityLabel() == text }
        }
        func textView(_ sheet: NSWindow?, _ text: String) -> NSTextView? {
            allViews(sheet?.contentView, as: NSTextView.self).first { $0.accessibilityLabel() == text }
        }
        func popup(_ sheet: NSWindow?, _ text: String) -> NSPopUpButton? {
            allViews(sheet?.contentView, as: NSPopUpButton.self).first { $0.accessibilityLabel() == text }
        }
        func selectRow(_ tableView: NSTableView, _ sheet: MetadataSheetController, _ row: Int) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            // Deterministic even if AppKit already delivered the delegate call.
            sheet.tableViewSelectionDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                          object: tableView))
        }
        func tagRow(_ sheet: MetadataSheetController, _ tagTable: NSTableView, _ tag: String) -> Int? {
            for row in 0..<sheet.numberOfRows(in: tagTable) {
                if sheet.tableView(tagTable, objectValueFor: nil, row: row) as? String == tag { return row }
            }
            return nil
        }
        func setEditor(_ sheet: MetadataSheetController, _ editor: NSTextView, _ text: String) {
            editor.string = text
            sheet.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            let deadline = Date().addingTimeInterval(10)
            while (document.pendingWork > 0 || EngineActivity.shared.isBusy) && Date() < deadline { spin(0.01) }
            spin()
        }

        let imageA = try session.newImage(width: 64, height: 64)
        let docA = try ImageDocument(session: session, image: imageA, name: "Meta A")
        documents.items.append(docA)
        let controllerA = DocumentWindowController(document: docA)
        controllerA.showWindow(nil)
        let imageB = try session.newImage(width: 64, height: 64)
        let docB = try ImageDocument(session: session, image: imageB, name: "Meta B")
        documents.items.append(docB)
        let controllerB = DocumentWindowController(document: docB)
        controllerB.showWindow(nil)
        // B front: every command issued on A must still land in A.
        controllerB.window?.makeKeyAndOrderFront(nil)
        var errorsA: [String] = []
        let reportErrorA = docA.onError
        docA.onError = { reportErrorA?($0); errorsA.append($0) }
        defer {
            for controller in [controllerA, controllerB] {
                if let sheet = controller.window?.attachedSheet {
                    controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                }
                controller.window?.orderOut(nil)
            }
            spin()
            documents.items.removeAll { $0 === docA || $0 === docB }
            for document in [docA, docB] where !document.isClosing {
                var closed = false
                document.closeImageWhenDrained { closed = true }
                let deadline = Date().addingTimeInterval(10)
                while !closed && Date() < deadline { spin(0.01) }
            }
            check((try? session.info(imageA)) == nil && (try? session.info(imageB)) == nil,
                  "both metadata-controls images drain and close before engine shutdown")
        }

        // Menu wiring: the item sits on the document's own selector and
        // validates from cached state only.
        let menu = MainMenu.make()
        let imageMenu = menu.items.first { $0.title == "Image" }?.submenu
        let metadataItem = imageMenu?.items.first { $0.title == "Metadata…" }
        check(metadataItem?.action == #selector(DocumentWindowController.showMetadata(_:)),
              "Image offers Metadata… on the document's selector")
        check(metadataItem.map { controllerA.validateMenuItem($0) } == true,
              "Metadata… validates with no sheet attached")

        // Seed one backend-supported tag through the document's counted
        // queue; the completion reports the engine's answer.
        var seedResult: Result<Void, Error>?
        docA.editMetadata("Exif.Image.Artist", .set, values: ["Alice"]) { seedResult = $0 }
        settle(docA)
        check(seedResult != nil && (try? session.metadataValues(imageA, tag: "Exif.Image.Artist")) == ["Alice"],
              "a queued SET lands on the oracle with its value")
        check((try? session.metadataTags(imageA, domain: .exif)).flatMap { $0.contains("Exif.Image.Artist") } == true,
              "the domain tag list reports the set tag")

        // Two documents open independent sheets through the actual action,
        // while B is front.
        controllerA.showMetadata(nil)
        controllerB.showMetadata(nil)
        let sheetA = controllerA.window?.attachedSheet
        let sheetB = controllerB.window?.attachedSheet
        check(sheetA != nil && sheetB != nil && sheetA !== sheetB
                && controllerA.metadataSheet !== controllerB.metadataSheet,
              "two documents open independent metadata sheets owned by their windows")
        check(metadataItem.map { controllerA.validateMenuItem($0) } == false,
              "Metadata… is disabled while its sheet is open")
        guard let sheetA, let metaSheetA = controllerA.metadataSheet, let sheetB, let metaSheetB = controllerB.metadataSheet else {
            check(false, "both metadata sheets are attached")
            return
        }
        let tagTableA = table(sheetA, "Metadata tag list")
        let tagTableB = table(sheetB, "Metadata tag list")
        check(tagTableA != nil && tagTableB != nil && tagTableA !== tagTableB,
              "each sheet has its own tag list, found by accessibility label")
        guard let tagTableA, let tagTableB else { return }
        wait { metaSheetA.numberOfRows(in: tagTableA) > 0 }
        check(tagRow(metaSheetA, tagTableA, "Exif.Image.Artist") != nil,
              "the sheet's queued tag load lists the seeded tag")
        settle(docB)
        check(metaSheetB.numberOfRows(in: tagTableB) == (try session.metadataTags(imageB, domain: .exif)).count
                && tagRow(metaSheetB, tagTableB, "Exif.Image.Artist") == nil,
              "document B shows its native default catalog and no Artist from document A")

        // Domain popup and full-catalog search: no truncation, order kept.
        check(popup(sheetA, "Metadata domain")?.titleOfSelectedItem == "EXIF",
              "the domain popup starts on EXIF")
        let allRowsBefore = metaSheetA.numberOfRows(in: tagTableA)
        editableField(sheetA, "Filter tags")?.stringValue = "artist"
        metaSheetA.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                     object: editableField(sheetA, "Filter tags")))
        check(metaSheetA.numberOfRows(in: tagTableA) == 1
                && metaSheetA.tableView(tagTableA, objectValueFor: nil, row: 0) as? String == "Exif.Image.Artist",
              "the catalog search filters case-insensitively without truncating the catalog")
        editableField(sheetA, "Filter tags")?.stringValue = ""
        metaSheetA.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                     object: editableField(sheetA, "Filter tags")))
        check(metaSheetA.numberOfRows(in: tagTableA) == allRowsBefore,
              "clearing the filter restores the full catalog in order")

        // Select the tag through the real table; its ordered values load
        // queued, and the editor shows the full value.
        guard let artistRow = tagRow(metaSheetA, tagTableA, "Exif.Image.Artist") else {
            check(false, "the seeded tag is listed")
            return
        }
        selectRow(tagTableA, metaSheetA, artistRow)
        let valuesTableA = table(sheetA, "Metadata value list")
        let editorA = textView(sheetA, "Selected metadata value editor")
        guard let valuesTableA, let editorA else {
            check(false, "the value list and multiline editor exist by label")
            return
        }
        wait { metaSheetA.numberOfRows(in: valuesTableA) == 1 }
        check(metaSheetA.selectedTag == "Exif.Image.Artist"
                && metaSheetA.tableView(valuesTableA, objectValueFor: nil, row: 0) as? String == "Alice"
                && editorA.string == "Alice",
              "selecting a tag loads its ordered values into rows and the editor")

        // A read in flight must not permit editing a draft that its
        // completion would replace.
        try session.editMetadata(imageA, tag: "Exif.Image.Copyright", .set, values: ["Rights"])
        try docA.reload()
        settle(docA)
        wait { tagRow(metaSheetA, tagTableA, "Exif.Image.Copyright") != nil }
        if let row = tagRow(metaSheetA, tagTableA, "Exif.Image.Copyright") {
            let readGate = DispatchSemaphore(value: 0)
            docA.inputQueue.async { readGate.wait() }
            selectRow(tagTableA, metaSheetA, row)
            check(button(sheetA, "Add metadata value")?.isEnabled == false && !editorA.isEditable,
                  "pending metadata values disable draft editing until the captured read returns")
            readGate.signal()
            settle(docA)
        }
        var keywordsSeeded = false
        docA.editMetadata("Iptc.Application2.Keywords", .set, values: ["Alice"]) { _ in keywordsSeeded = true }
        wait { keywordsSeeded && docA.pendingWork == 0 }
        func chooseDomain(_ index: Int) {
            if let control = popup(sheetA, "Metadata domain") {
                control.selectItem(at: index)
                control.sendAction(control.action, to: control.target)
            }
            settle(docA)
        }
        chooseDomain(1)
        if let row = tagRow(metaSheetA, tagTableA, "Iptc.Application2.Keywords") {
            selectRow(tagTableA, metaSheetA, row)
            settle(docA)
        } else { check(false, "the repeatable IPTC keyword tag is listed") }

        // Edit through the real controls: multiline text, duplicates and
        // an empty string as separate ordered draft rows.
        setEditor(metaSheetA, editorA, "line1\nline2")
        button(sheetA, "Add metadata value")?.performClick(nil)
        setEditor(metaSheetA, editorA, "dup")
        button(sheetA, "Add metadata value")?.performClick(nil)
        setEditor(metaSheetA, editorA, "dup")
        button(sheetA, "Add metadata value")?.performClick(nil)
        // The new row is the empty string — a value, not a missing entry.
        check(metaSheetA.numberOfRows(in: valuesTableA) == 4
                && metaSheetA.tableView(valuesTableA, objectValueFor: nil, row: 0) as? String == "line1\nline2"
                && metaSheetA.tableView(valuesTableA, objectValueFor: nil, row: 1) as? String == "dup"
                && metaSheetA.tableView(valuesTableA, objectValueFor: nil, row: 2) as? String == "dup"
                && metaSheetA.tableView(valuesTableA, objectValueFor: nil, row: 3) as? String == "",
              "the draft keeps the multiline text, duplicate and empty value as separate ordered rows")
        // Remove Value edits the local draft only.
        selectRow(valuesTableA, metaSheetA, 3)
        button(sheetA, "Remove metadata value")?.performClick(nil)
        check(metaSheetA.numberOfRows(in: valuesTableA) == 3,
              "Remove Value deletes the explicit selected row from the local draft")
        button(sheetA, "Add metadata value")?.performClick(nil)
        let attemptedValues = ["line1\nline2", "dup", "dup", ""]

        // Apply behind a controlled input-queue gate: counted, controls
        // disabled, capture explicit; the gate is released on every path.
        let gate = DispatchSemaphore(value: 0)
        docA.inputQueue.async { gate.wait() }
        defer { gate.signal() }
        let workBeforeApply = docA.pendingWork
        let undoBeforeApply = docA.undoInfo.undoCount
        button(sheetA, "Apply metadata values")?.performClick(nil)
        check(docA.pendingWork == workBeforeApply + 2
                && button(sheetA, "Apply metadata values")?.isEnabled == false,
              "an accepted Apply is counted as pending work and disables the write controls")
        check(popup(sheetA, "Metadata domain")?.isEnabled == false && !tagTableA.isEnabled,
              "an applying metadata command freezes tag and domain selection")
        check(metaSheetA.lastCapture == MetadataSheetLogic.Capture(image: imageA, tag: "Iptc.Application2.Keywords",
                                                                   action: .setValues, values: attemptedValues),
              "Apply captures the image, tag, action and the ordered value-array snapshot")
        gate.signal()
        wait { docA.pendingWork == workBeforeApply }
        settle(docA)
        check(try session.metadataValues(imageA, tag: "Iptc.Application2.Keywords") == ["Alice"]
                && docA.undoInfo.undoCount == undoBeforeApply && metaSheetA.lastError != nil
                && metaSheetA.numberOfRows(in: valuesTableA) == 4,
              "an unrepresentable empty member is refused with the native value, history and local draft intact")
        errorsA.removeAll()
        selectRow(valuesTableA, metaSheetA, 3)
        button(sheetA, "Remove metadata value")?.performClick(nil)
        let expectedValues = ["line1\nline2", "dup", "dup"]
        button(sheetA, "Apply metadata values")?.performClick(nil)
        settle(docA)
        let committedValues = try session.metadataValues(imageA, tag: "Iptc.Application2.Keywords")
        check(committedValues == expectedValues,
              "the committed whole array preserves order, duplicates, and the newline exactly (actual \(String(reflecting: committedValues)))")
        check(docA.undoInfo.undoCount == undoBeforeApply + 1,
              "the SET is exactly one undo step")
        check(metaSheetA.lastError == nil && (label(sheetA, "Metadata message")?.stringValue ?? "").isEmpty,
              "a successful Apply clears the error row")

        // No-op: applying the identical values again adds no undo step.
        button(sheetA, "Apply metadata values")?.performClick(nil)
        wait { docA.pendingWork == workBeforeApply }
        settle(docA)
        check(docA.undoInfo.undoCount == undoBeforeApply + 1,
              "applying the identical value list is a no-op with no undo")

        // Adding a known absent tag creates only a local draft. The
        // user supplies text before the first native write.
        let beforeNewTag = docA.undoInfo.undoCount
        editableField(sheetA, "New tag name")?.stringValue = "Iptc.Application2.Credit"
        button(sheetA, "Add tag")?.performClick(nil)
        settle(docA)
        let tagsBeforeNewApply = try session.metadataTags(imageA, domain: .iptc)
        check(metaSheetA.selectedTag == "Iptc.Application2.Credit"
                && editorA.string.isEmpty && metaSheetA.numberOfRows(in: valuesTableA) == 1
                && docA.undoInfo.undoCount == beforeNewTag
                && !tagsBeforeNewApply.contains("Iptc.Application2.Credit"),
              "Add Tag validates a registered name and starts an unapplied local draft without native changes")
        setEditor(metaSheetA, editorA, "Credit Line")
        button(sheetA, "Apply metadata values")?.performClick(nil)
        settle(docA)
        check(try session.metadataValues(imageA, tag: "Iptc.Application2.Credit") == ["Credit Line"]
                && docA.undoInfo.undoCount == beforeNewTag + 1,
              "Apply adds the new tag with its actual entered value as one undo step")
        docA.undo()
        settle(docA)
        check(try session.metadataValues(imageA, tag: "Iptc.Application2.Credit").isEmpty
                && docA.undoInfo.undoCount == beforeNewTag,
              "one undo removes the newly applied tag")

        // A native refusal stays visible and never updates rows or draft
        // as if accepted: an unregistered dotted name is NOT_FOUND.
        let captureBeforeInvalidTag = metaSheetA.lastCapture
        editableField(sheetA, "New tag name")?.stringValue = "Iptc.Application2.DefinitelyNotRegistered"
        button(sheetA, "Add tag")?.performClick(nil)
        wait { metaSheetA.lastError != nil }
        settle(docA)
        check(!(label(sheetA, "Metadata message")?.stringValue ?? "").isEmpty
                && metaSheetA.lastError != nil
                && tagRow(metaSheetA, tagTableA, "Iptc.Application2.DefinitelyNotRegistered") == nil
                && (try? session.metadataValues(imageA, tag: "Iptc.Application2.DefinitelyNotRegistered")) == nil,
              "an unregistered Add Tag is refused with the native error shown, nothing queued as accepted, no false row")
        check(metaSheetA.lastCapture == captureBeforeInvalidTag,
              "unregistered tag validation never queues or captures a native write")

        // A protected (normalization-rewritten) tag is read-only in the UI.
        chooseDomain(0)
        wait { tagRow(metaSheetA, tagTableA, "Exif.Image.ImageWidth") != nil }
        if let protectedRow = tagRow(metaSheetA, tagTableA, "Exif.Image.ImageWidth") {
            selectRow(tagTableA, metaSheetA, protectedRow)
            check(button(sheetA, "Apply metadata values")?.isEnabled == false
                    && button(sheetA, "Remove metadata tag")?.isEnabled == false
                    && button(sheetA, "Add metadata value")?.isEnabled == false
                    && (label(sheetA, "Metadata note")?.stringValue ?? "").contains("read-only") == true,
                  "a normalization-protected tag is shown read-only with the reason")
        } else {
            check(false, "the first edit's normalization lists the protected dimension tag")
        }

        chooseDomain(1)

        // An empty value list is not a SET: refused locally, actionably,
        // with no native call. (Re-look-up the row: reloads may reorder.)
        guard let artistRowAgain = tagRow(metaSheetA, tagTableA, "Iptc.Application2.Keywords") else {
            check(false, "the tag is still listed before the empty-SET refusal")
            return
        }
        selectRow(tagTableA, metaSheetA, artistRowAgain)
        wait { metaSheetA.numberOfRows(in: valuesTableA) == expectedValues.count }
        for _ in 0..<expectedValues.count {
            if metaSheetA.numberOfRows(in: valuesTableA) > 0 {
                selectRow(valuesTableA, metaSheetA, 0)
                button(sheetA, "Remove metadata value")?.performClick(nil)
            }
        }
        check(metaSheetA.numberOfRows(in: valuesTableA) == 0, "the draft can be emptied locally")
        let workBeforeEmpty = docA.pendingWork
        button(sheetA, "Apply metadata values")?.performClick(nil)
        check(docA.pendingWork == workBeforeEmpty
                && (label(sheetA, "Metadata message")?.stringValue ?? "").contains("Remove Tag") == true,
              "an empty value list is refused locally with the Remove Tag explanation, nothing queued")
        check(try session.metadataValues(imageA, tag: "Iptc.Application2.Keywords") == expectedValues,
              "the refused empty SET did not touch the native values")

        // Restore the values through the sheet, then undo/redo them.
        for value in expectedValues {
            button(sheetA, "Add metadata value")?.performClick(nil)
            setEditor(metaSheetA, editorA, value)
        }
        button(sheetA, "Apply metadata values")?.performClick(nil)
        wait { docA.pendingWork == workBeforeEmpty }
        settle(docA)
        check(try session.metadataValues(imageA, tag: "Iptc.Application2.Keywords") == expectedValues,
              "re-applying the restored draft commits the same ordered array")
        docA.undo()
        settle(docA)
        check(try session.metadataValues(imageA, tag: "Iptc.Application2.Keywords") == ["Alice"],
              "undo restores the seeded keyword rather than removing an existing tag")
        wait { editorA.string == "Alice" && metaSheetA.numberOfRows(in: valuesTableA) == 1 }
        check(editorA.string == "Alice" && metaSheetA.numberOfRows(in: valuesTableA) == 1,
              "Undo refreshes values for the same selected metadata tag")
        docA.redo()
        settle(docA)
        check(try session.metadataValues(imageA, tag: "Iptc.Application2.Keywords") == expectedValues,
              "redo restores the exact ordered values")

        // Save/reopen round trip for the backend-supported tag.
        let xcf = work.appendingPathComponent("metadata-controls.xcf")
        try session.save(imageA, to: xcf.path)
        let reopened = try session.openImage(path: xcf.path)
        defer { try? session.closeImage(reopened) }
        check(try session.metadataValues(reopened, tag: "Iptc.Application2.Keywords") == expectedValues
                && (try session.metadataTags(reopened, domain: .iptc)).contains("Iptc.Application2.Keywords"),
              "save and reopen retain the tag and its ordered multiline/duplicate values")

        // Two-document capture: B, frontmost, is untouched by all of A's
        // sheet work.
        check((try? session.metadataTags(imageB, domain: .iptc)).flatMap({ $0.contains("Iptc.Application2.Keywords") }) != true,
              "the front document B never received A's tag (captured document, not front)")

        // Queued completion, close drain and late results: accept an edit
        // on B, close while it is queued, the completion still lands and
        // the image is destroyed only after the drain.
        var lateEdit: Result<Void, Error>?
        let workBeforeAccept = docB.pendingWork
        docB.editMetadata("Iptc.Application2.Caption", .set, values: ["B caption"]) { lateEdit = $0 }
        check(docB.pendingWork == workBeforeAccept + 2, "an accepted metadata edit on B is counted")
        var closedB = false
        docB.closeImageWhenDrained { closedB = true }
        let closeDeadline = Date().addingTimeInterval(10)
        while !closedB && Date() < closeDeadline { spin(0.01) }
        check(closedB && lateEdit != nil && (try? session.info(imageB)) == nil,
              "close drains the counted metadata edit before destroying the image, and its completion lands")
        var lateRead: Result<[String], Error>?
        docB.readMetadataTags(.exif) { lateRead = $0 }
        spin()
        check(lateRead != nil && (try? session.info(imageB)) == nil,
              "a read requested after close fails through its completion without crashing")

        // Closing the sheet invalidates it: late callbacks neither update
        // nor resurrect it.
        controllerA.window?.endSheet(sheetA, returnCode: .alertSecondButtonReturn)
        wait { controllerA.metadataSheet == nil && controllerA.window?.attachedSheet == nil }
        check(controllerA.metadataSheet == nil, "ending the sheet releases the window's retain")
        let errorBefore = metaSheetA.lastError
        metaSheetA.showError("late error after close")
        metaSheetA.documentStateDidChange()
        check(metaSheetA.lastError == errorBefore,
              "a late error/state callback on the invalidated sheet changes nothing")
        documents.items.removeAll { $0 === docB }
    }
}
