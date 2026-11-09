import AppKit
import RigiUI

/// Real metadata descriptor controls, dispatched alone and in the full
/// engine smoke run. Lookup uses accessibility labels; native metadata
/// drives the format gates, Undo presence transition and draft retention.
@MainActor
extension EngineSmokeTest {
    static func exerciseMetadataDescriptors(_ session: EngineSession, work: URL,
                                            documents: DocumentList) throws {
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
            sheet.tableViewSelectionDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                          object: tableView))
        }
        func tagRow(_ sheet: MetadataSheetController, _ tagTable: NSTableView, _ tag: String) -> Int? {
            for row in 0..<sheet.numberOfRows(in: tagTable) {
                if sheet.tableView(tagTable, objectValueFor: nil, row: row) as? String == tag { return row }
            }
            return nil
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            let deadline = Date().addingTimeInterval(10)
            while (document.pendingWork > 0 || EngineActivity.shared.isBusy) && Date() < deadline { spin(0.01) }
            spin()
        }

        let image = try session.newImage(width: 64, height: 64)
        let doc = try ImageDocument(session: session, image: image, name: "Meta Descriptors")
        documents.items.append(doc)
        let controller = DocumentWindowController(document: doc)
        controller.showWindow(nil)
        var seedResult: Result<Void, Error>?
        doc.editMetadata("Exif.Image.Artist", .set, values: ["Alice"]) { seedResult = $0 }
        settle(doc)
        check(seedResult != nil, "the seeded SET lands")
        doc.editMetadata("Iptc.Application2.Keywords", .set, values: ["k1"]) { _ in }
        settle(doc)
        defer {
            if let sheet = controller.window?.attachedSheet {
                controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
            }
            controller.window?.orderOut(nil)
            spin()
            documents.items.removeAll { $0 === doc }
            if !doc.isClosing {
                var closed = false
                doc.closeImageWhenDrained { closed = true }
                let deadline = Date().addingTimeInterval(10)
                while !closed && Date() < deadline { spin(0.01) }
            }
        }

        controller.showMetadata(nil)
        guard let sheet = controller.window?.attachedSheet, let metaSheet = controller.metadataSheet else {
            check(false, "the metadata sheet is attached")
            return
        }
        let tagTable = table(sheet, "Metadata tag list")
        guard let tagTable else { check(false, "tag list found"); return }
        wait { tagRow(metaSheet, tagTable, "Exif.Image.Artist") != nil }

        // EXIF single scalar: descriptor display + SET allowed, Add Value not.
        if let row = tagRow(metaSheet, tagTable, "Exif.Image.Artist") {
            selectRow(tagTable, metaSheet, row)
            settle(doc)
            wait { metaSheet.tagDescriptor != nil }
            check(metaSheet.tagDescriptor?.valueKind == .single
                    && metaSheet.tagDescriptor?.present == true,
                  "the single scalar's descriptor arrives with its kind and presence")
            check((label(sheet, "Metadata tag descriptor")?.stringValue ?? "").contains("Artist") == true,
                  "the native label is shown in the descriptor title")
            check((label(sheet, "Metadata tag presence")?.stringValue ?? "").contains("Present") == true,
                  "the presence line reports the present tag")
            check(button(sheet, "Apply metadata values")?.isEnabled == true,
                  "SET is enabled for a policy-admitted single scalar once reads landed")
            check(button(sheet, "Add metadata value")?.isEnabled == false,
                  "a .single tag cannot Add Value")
            check(button(sheet, "Remove metadata tag")?.isEnabled == true,
                  "REMOVE gates independently on its own bit")
        } else { check(false, "the seeded tag is listed") }

        // IPTC repeatable: Add Value enabled once the descriptor lands.
        if let popup = popup(sheet, "Metadata domain") {
            popup.selectItem(at: 1)
            popup.sendAction(popup.action, to: popup.target)
        }
        settle(doc)
        wait { tagRow(metaSheet, tagTable, "Iptc.Application2.Keywords") != nil }
        if let row = tagRow(metaSheet, tagTable, "Iptc.Application2.Keywords") {
            selectRow(tagTable, metaSheet, row)
            settle(doc)
            wait { metaSheet.tagDescriptor?.valueKind == .repeatable }
            check(button(sheet, "Add metadata value")?.isEnabled == true,
                  "a repeatable tag with native multiple support can Add Value")
            check(metaSheet.tagDescriptor?.supportsMultiple == true,
                  "the native multiple flag is part of the descriptor")
        } else { check(false, "the repeatable tag is listed") }

        // XMP LangAlt: visibly read-only from the descriptor, before any
        // native edit could fail.
        if let popup = popup(sheet, "Metadata domain") {
            popup.selectItem(at: 2)
            popup.sendAction(popup.action, to: popup.target)
        }
        settle(doc)
        // The catalog lists present tags, not every registered XMP name.
        // Inspect a registered absent LangAlt through Add Tag validation.
        editableField(sheet, "New tag name")?.stringValue = "Xmp.dc.title"
        button(sheet, "Add tag")?.performClick(nil)
        settle(doc)
        if metaSheet.selectedTag == "Xmp.dc.title" {
            wait { metaSheet.tagDescriptor?.valueKind == .langAlt }
            check(metaSheet.tagDescriptor?.supportsMultiple == true,
                  "LangAlt carries the native multiple flag and is still read-only")
            check(button(sheet, "Apply metadata values")?.isEnabled == false
                    && button(sheet, "Remove metadata tag")?.isEnabled == false
                    && button(sheet, "Add metadata value")?.isEnabled == false,
                  "LangAlt gates every write off before a failed native edit")
            let languageNote = label(sheet, "Metadata note")?.stringValue ?? ""
            check(languageNote.contains(MetadataSheetLogic.langAltNote) && languageNote.contains("read-only"),
                  "the read-only reason is shown for LangAlt")
            check(textView(sheet, "Selected metadata value editor")?.isEditable == false,
                  "the editor is read-only for LangAlt")
        } else { check(false, "the registered LangAlt descriptor is shown") }

        // Absent XMP bag via Add Tag: local draft only, Apply disabled,
        // Remove Tag permitted (the native no-op).
        let undoBefore = doc.undoInfo.undoCount
        editableField(sheet, "New tag name")?.stringValue = "Xmp.dc.subject"
        button(sheet, "Add tag")?.performClick(nil)
        settle(doc)
        wait { metaSheet.tagDescriptor != nil }
        check(metaSheet.selectedTag == "Xmp.dc.subject" && metaSheet.tagDescriptor?.valueKind == .bag
                && metaSheet.tagDescriptor?.present == false,
              "the absent bag is selected and its descriptor reports absent")
        check(button(sheet, "Apply metadata values")?.isEnabled == false,
              "an absent container has SET unavailable")
        check(button(sheet, "Remove metadata tag")?.isEnabled == true,
              "an absent container keeps REMOVE permitted")
        check((label(sheet, "Metadata note")?.stringValue ?? "").contains("Remove Tag") == true,
              "the absent-container reason names Remove Tag")
        check(doc.undoInfo.undoCount == undoBefore
                && (try? session.metadataTags(image, domain: .xmp)).flatMap({ $0.contains("Xmp.dc.subject") }) != true,
              "Add Tag on an absent container performs no native write")

        // Unregistered Add Tag: the native NOT_FOUND is visible, no false row.
        if let popup = popup(sheet, "Metadata domain") {
            popup.selectItem(at: 1)
            popup.sendAction(popup.action, to: popup.target)
        }
        settle(doc)
        editableField(sheet, "New tag name")?.stringValue = "Iptc.Application2.GlimsDefinitelyNotRegistered"
        button(sheet, "Add tag")?.performClick(nil)
        wait { metaSheet.lastError != nil }
        settle(doc)
        check((label(sheet, "Metadata message")?.stringValue ?? "").isEmpty == false,
              "the unregistered tag's query error is visible in the message row")
        check(tagRow(metaSheet, tagTable, "Iptc.Application2.GlimsDefinitelyNotRegistered") == nil,
              "no false tag row is created")

        // Keep a dirty local draft selected while Undo removes its native
        // tag: presence must change, but those local rows must not disappear.
        if let row = tagRow(metaSheet, tagTable, "Iptc.Application2.Keywords") {
            selectRow(tagTable, metaSheet, row)
            settle(doc)
            check(metaSheet.tagDescriptor?.present == true, "the selected tag is present before Undo")
            button(sheet, "Add metadata value")?.performClick(nil)
            let rowsBefore = table(sheet, "Metadata value list")?.numberOfRows
            doc.undo() // The last native edit seeded Keywords.
            settle(doc)
            check(metaSheet.tagDescriptor?.present == false
                    && (label(sheet, "Metadata tag presence")?.stringValue ?? "").contains("Not present")
                    && (try? session.metadataValues(image, tag: "Iptc.Application2.Keywords")) == [],
                  "Undo refreshes the descriptor after its present tag becomes absent")
            check(rowsBefore == 2 && table(sheet, "Metadata value list")?.numberOfRows == rowsBefore,
                  "descriptor refresh preserves the dirty local value draft")
        } else { check(false, "the Undo presence fixture finds Keywords") }

        // Close invalidates the sheet: late callbacks neither update nor
        // reopen it; the queued reads still drained through close.
        controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        wait { controller.metadataSheet == nil && controller.window?.attachedSheet == nil }
        let errorBefore = metaSheet.lastError
        let descriptorBefore = metaSheet.tagDescriptor
        metaSheet.showError("late error after close")
        metaSheet.documentStateDidChange()
        check(metaSheet.lastError == errorBefore && metaSheet.tagDescriptor == descriptorBefore,
              "a late callback on the invalidated sheet changes nothing")
    }
}
