import AppKit

private struct MetadataRatingBaselineSnapshot: Equatable {
    let rating: [String]
    let artist: [String]
    let pixels: Data
    let history: EngineSession.UndoInfo
    let layers: [EngineSession.Layer]
    let selection: [Int32]
    let isDirty: Bool

    init(_ session: EngineSession, image: Int32) throws {
        rating = try session.metadataValues(image, tag: "Xmp.xmp.Rating")
        artist = try session.metadataValues(image, tag: "Exif.Image.Artist")
        pixels = try session.copyPixels(image, merged: true).pixels
        history = try session.undoInfo(image)
        layers = try session.layers(image)
        selection = try session.selectedLayers(image)
        isDirty = try session.info(image).isDirty
    }
}

@MainActor
extension EngineSmokeTest {
    /// Independent pre-product baseline: existing native metadata APIs and
    /// public AppKit traversal only. The expected old-code failure is the
    /// missing Edit Rating action, after the actual tag/value is selected.
    static func exerciseMetadataRating(_ session: EngineSession, documents: DocumentList) throws {
        var image: Int32?
        var document: ImageDocument?
        var controller: DocumentWindowController?
        var original: MetadataRatingBaselineSnapshot?
        func all<T: NSView>(_ root: NSView?, _ type: T.Type) -> [T] {
            guard let root else { return [] }
            return ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { all($0, type) }
        }
        func button(_ window: NSWindow?, _ label: String) -> NSButton? {
            all(window?.contentView, NSButton.self).first { $0.accessibilityLabel() == label }
        }
        func waitFor(_ message: String, _ condition: () -> Bool) -> Bool {
            let limit = Date().addingTimeInterval(15)
            while Date() < limit {
                if condition() { return true }
                spin(0.01)
            }
            check(false, "Timed out: \(message)")
            return false
        }
        func nativeImageGone(_ id: Int32) -> Bool {
            do { _ = try session.info(id); return false }
            catch { return (error as? EngineSession.EngineError)?.isNotFound == true }
        }
        defer {
            if let owner = controller?.window, let panel = owner.attachedSheet {
                if let close = button(panel, "Close metadata sheet") {
                    close.performClick(nil)
                    _ = waitFor("owned metadata sheet closes", { owner.attachedSheet == nil })
                }
                if owner.attachedSheet === panel {
                    NSApp.endSheet(panel, returnCode: NSApplication.ModalResponse.abort.rawValue)
                    spin(0.03)
                }
            }
            if let document {
                _ = waitFor("metadata baseline reads drain", { document.pendingWork == 0 && !EngineActivity.shared.isBusy })
            }
            if let original, let image {
                check((try? MetadataRatingBaselineSnapshot(session, image: image)) == original,
                      "closing the metadata baseline discards no stored value and preserves pixels/history/unrelated tags")
            }
            document?.beginClosing()
            controller?.window?.orderOut(nil)
            var stopped = controller == nil
            controller?.canvas.stopRendering { stopped = true }
            _ = waitFor("metadata rating baseline renderer drains", { stopped })
            check(stopped, "metadata rating baseline teardown drains its owned renderer")
            if let document { document.closeImageWhenDrained() }
            else if let image { try? session.closeImage(image) }
            let gone = image.map { id in waitFor("metadata rating baseline image closes", { nativeImageGone(id) }) } ?? true
            check(gone, "metadata rating baseline teardown closes its owned native image")
            controller?.window?.close()
            spin(0.03)
            check(controller?.window?.attachedSheet == nil,
                  "metadata rating baseline teardown leaves no owned sheet or dialog")
            if let document { documents.items.removeAll { $0 === document } }
        }

        let id = try session.newImage(width: 24, height: 16)
        image = id
        var bytes: [UInt8] = []
        for y in 0..<16 {
            for x in 0..<24 {
                bytes.append(UInt8(20 + (x * 19 + y * 7) % 210))
                bytes.append(UInt8(30 + (x * 3 + y * 23) % 200))
                bytes.append(UInt8(40 + (x * 11 + y * 5) % 190))
                bytes.append(255)
            }
        }
        let patterned = ClipboardImage(width: 24, height: 16, pixels: Data(bytes), origin: .zero)
        _ = try session.pastePixels(id, pixels: patterned, at: .zero)
        let tag = "Xmp.xmp.Rating"
        try session.editMetadata(id, tag: tag, .set, values: ["2.5"])
        try session.editMetadata(id, tag: "Exif.Image.Artist", .set, values: ["Independent rating baseline"])
        let info = try session.metadataTagInfo(id, tag: tag)
        let capable = info.present && info.valueKind == .single && !info.supportsMultiple
            && info.typeName == "XmpText" && info.formatPolicy.contains(.supportsSet)
            && info.formatPolicy.contains(.supportsRemove)
        check(capable, "the loaded engine freshly reports present scalar XmpText Rating with SET/REMOVE capability")
        // Unsupported or unexpected capability is a failed fixture, not a
        // skipped success. The intended old-code failure is farther below.
        guard capable else { return }
        let before = try MetadataRatingBaselineSnapshot(session, image: id)
        let floating = try session.floatingSelection(id)
        original = before
        check(before.rating == ["2.5"] && before.artist == ["Independent rating baseline"]
              && before.pixels == Data(bytes) && !floating.isActive,
              "native setup preserves fractional Rating, unrelated metadata and patterned pixels on an ordinary nonfloating layer")
        let ownerDocument = try ImageDocument(session: session, image: id, name: "Metadata Rating Baseline")
        document = ownerDocument
        documents.items.append(ownerDocument)
        let ownerController = DocumentWindowController(document: ownerDocument)
        controller = ownerController
        ownerController.showWindow(nil)
        guard let item = NSApp.mainMenu?.item(withTitle: "Image")?.submenu?.items.first(where: {
            $0.action == #selector(DocumentWindowController.showMetadata(_:))
        }) else { return check(false, "the installed Image menu exposes Metadata") }
        check(ownerController.validateMenuItem(item), "the actual Image menu admits the existing Metadata action")
        _ = NSApp.sendAction(#selector(DocumentWindowController.showMetadata(_:)), to: ownerController, from: item)
        guard waitFor("the actual metadata panel opens", { ownerController.window?.attachedSheet?.isVisible == true }),
              let panel = ownerController.window?.attachedSheet,
              let domain = all(panel.contentView, NSPopUpButton.self).first(where: { $0.accessibilityLabel() == "Metadata domain" }),
              let table = all(panel.contentView, NSTableView.self).first(where: { $0.accessibilityLabel() == "Metadata tag list" }),
              let editor = all(panel.contentView, NSTextView.self).first(where: { $0.accessibilityLabel() == "Selected metadata value editor" }),
              let descriptor = all(panel.contentView, NSTextField.self).first(where: { $0.accessibilityLabel() == "Metadata tag descriptor" }),
              let domainAction = domain.action else {
            return check(false, "the real metadata panel provides its public domain/tag/value/descriptor controls")
        }
        check(panel.sheetParent === ownerController.window && panel.isVisible,
              "the actual Metadata panel belongs to the captured document window")
        domain.selectItem(withTitle: "XMP")
        _ = NSApp.sendAction(domainAction, to: domain.target, from: domain)
        func ratingRow() -> Int? {
            (0..<table.numberOfRows).first { row in
                table.dataSource?.tableView?(table, objectValueFor: table.tableColumns.first, row: row) as? String == tag
            }
        }
        guard waitFor("the actual XMP table lists the seeded Rating", { ratingRow() != nil }),
              let row = ratingRow() else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard waitFor("selected Rating values and descriptor finish their counted reads", {
            table.selectedRow == row && editor.string == "2.5"
                && descriptor.stringValue.contains("XmpText") && ownerDocument.pendingWork == 0
        }) else { return }
        check(table.selectedRow == row && editor.string == "2.5" && descriptor.stringValue.contains("XmpText"),
              "public AppKit selection shows the exact native fractional Rating and its current descriptor")

        // This is the single intended baseline RED. It names no future
        // controller, policy, selector or test-only product access point.
        let launch = button(panel, "Edit XMP rating")
        check(launch?.title == "Edit Rating…" && launch?.isEnabled == true
              && launch?.isHiddenOrHasHiddenAncestor == false && launch?.action != nil,
              "selected supported Rating exposes a visible enabled Edit Rating action")
        check(try MetadataRatingBaselineSnapshot(session, image: id) == before
              && ownerDocument.undoInfo == before.history && ownerDocument.pendingWork == 0,
              "inspecting Rating and the missing typed action preserves native values, pixels, complete history and document state")
    }
}
