import AppKit

@MainActor
extension EngineSmokeTest {
    /// Run only with the test facade proxy. All editing still uses the real
    /// native engine; only Credit's descriptor reports a deterministic error.
    static func exerciseMetadataDescriptorFailures(_ session: EngineSession, documents: DocumentList) throws {
        func views<T: NSView>(_ root: NSView?, _ type: T.Type) -> [T] {
            guard let root else { return [] }
            return ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views($0, type) }
        }
        func settle(_ doc: ImageDocument) {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                doc.inputQueue.sync {}
                spin(0.02)
            } while doc.pendingWork > 0 && Date() < deadline
        }
        let tag = "Iptc.Application2.Credit"
        let image = try session.newImage(width: 32, height: 32)
        let doc = try ImageDocument(session: session, image: image, name: "Descriptor Failure")
        documents.items.append(doc)
        let window = DocumentWindowController(document: doc)
        window.showWindow(nil)
        defer {
            if let sheet = window.window?.attachedSheet { window.window?.endSheet(sheet) }
            window.window?.orderOut(nil)
            spin()
            documents.items.removeAll { $0 === doc }
            doc.closeImageWhenDrained()
            settle(doc)
        }
        doc.editMetadata(tag, .set, values: ["Credit"]) { _ in }
        settle(doc)
        doc.editMetadata("Exif.Image.Artist", .set, values: ["Alice"]) { _ in }
        settle(doc)

        func openIPTC() -> (MetadataSheetController, NSWindow)? {
            window.showMetadata(nil)
            guard let meta = window.metadataSheet, let sheet = window.window?.attachedSheet,
                  let domain = views(sheet.contentView, NSPopUpButton.self)
                    .first(where: { $0.accessibilityLabel() == "Metadata domain" }),
                  let action = domain.action else { return nil }
            domain.selectItem(at: 1)
            NSApp.sendAction(action, to: domain.target, from: domain)
            settle(doc)
            return (meta, sheet)
        }
        func message(_ sheet: NSWindow) -> String {
            views(sheet.contentView, NSTextField.self)
                .first { $0.accessibilityLabel() == "Metadata message" }?.stringValue ?? ""
        }
        guard let (meta, sheet) = openIPTC(),
              let tags = views(sheet.contentView, NSTableView.self)
                .first(where: { $0.accessibilityLabel() == "Metadata tag list" }),
              let row = (0..<meta.numberOfRows(in: tags)).first(where: {
                  meta.tableView(tags, objectValueFor: nil, row: $0) as? String == tag
              }) else { return check(false, "descriptor failure fixture finds its present tag") }
        tags.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        settle(doc)
        check(message(sheet).contains("Injected metadata descriptor read failure"),
              "a failed descriptor query displays its native error")
        doc.undo() // Artist disappears; the selected Credit tag stays present.
        settle(doc)
        check(message(sheet).contains("Injected metadata descriptor read failure"),
              "a later successful value read cannot erase the descriptor failure after Undo")
        window.window?.endSheet(sheet)
        spin()
        doc.editMetadata(tag, .remove) { _ in }
        settle(doc)
        guard let (_, fresh) = openIPTC(),
              let name = views(fresh.contentView, NSTextField.self).first(where: { $0.accessibilityLabel() == "New tag name" }),
              let add = views(fresh.contentView, NSButton.self).first(where: { $0.accessibilityLabel() == "Add tag" }),
              let values = views(fresh.contentView, NSTableView.self).first(where: { $0.accessibilityLabel() == "Metadata value list" })
        else { return check(false, "new tag failure fixture opens its controls") }
        let undo = doc.undoInfo.undoCount
        name.stringValue = tag
        add.performClick(nil)
        settle(doc)
        check(values.numberOfRows == 0 && window.metadataSheet?.tagDescriptor == nil,
              "failed descriptor validation creates no half-validated new tag draft")
        check(try session.metadataValues(image, tag: tag).isEmpty && doc.undoInfo.undoCount == undo,
              "failed new tag validation leaves native metadata and history unchanged")
    }
}
