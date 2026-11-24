import AppKit
import CGlimsEngine

@MainActor
extension EngineSmokeTest {
    /// Slot 266 exercised through the real Image menu path: a yellow block
    /// spreads under the neighbouring cyan block of a native CMYK document,
    /// one Undo step named "Trap" records it, and an RGB document refuses.
    static func exerciseTrap(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin(0.02)
        }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        func buttons(_ view: NSView?) -> [NSButton] {
            guard let view else { return [] }
            return ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons($0) }
        }

        guard session.supportsTrap else {
            return check(false, "trap: the engine exports slot 266 image_trap")
        }
        let profiles = PsdCmykProfileCatalog.discoveredEntries()
        guard let profile = profiles.first else {
            print("skipped: no CMYK profile installed (supported skip)")
            return
        }

        var owned: [ImageDocument] = []
        var controllers: [DocumentWindowController] = []
        let previousMenu = NSApp.mainMenu
        defer {
            for controller in controllers {
                if let window = controller.window, let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil)
                }
                if !controller.closeStarted { controller.closeDiscardingChanges() }
            }
            for document in owned { document.closeImageWhenDrained() }
            wait { owned.allSatisfy { (try? session.info($0.image)) == nil } }
            documents.items.removeAll { document in owned.contains { $0 === document } }
            NSApp.mainMenu = previousMenu
        }

        let image = try session.newCmykImage(width: 16, height: 8, component: .u8,
                                             profileICC: profile.profile.iccData)
        let document = try ImageDocument(session: session, image: image, name: "Trap")
        owned.append(document)
        documents.items.append(document)
        let controller = DocumentWindowController(document: document, exportDirectory: work)
        controllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        settle(document)
        guard document.channels.count == 4 else {
            return check(false, "trap: the CMYK document exposes four ink channels")
        }
        let cyanChannel = document.channels[0].id
        let yellowChannel = document.channels[2].id

        func paint(_ channel: Int32, _ rect: CGRect, _ label: String) {
            var options = EngineSession.SelectOptions()
            options.antialias = false
            document.select(.rectangle(rect), options: options)
            settle(document)
            document.refreshSelection()
            settle(document)
            document.selectChannel(channel)
            settle(document)
            var failure: Error?
            var completed = false
            _ = document.editInk(.init(operation: .fill, intensity: 0, opacity: 1),
                                 channel: channel) { result in
                completed = true
                if case .failure(let error) = result { failure = error }
            }
            settle(document)
            wait { completed }
            check(completed && failure == nil, "trap: the \(label) block is painted" +
                  (failure.map { " (\($0))" } ?? ""))
        }

        paint(yellowChannel, CGRect(x: 0, y: 0, width: 4, height: 8), "yellow")
        paint(cyanChannel, CGRect(x: 4, y: 0, width: 12, height: 8), "cyan")
        check(pixel(session, image, x: 1, y: 4) != pixel(session, image, x: 6, y: 4),
              "trap: the fixture paints distinct yellow and cyan blocks")

        document.select(.none)
        settle(document)
        document.refreshSelection()
        settle(document)
        let undoBeforeTrap = try session.undoInfo(image).undoCount
        // Component documents refuse pixel copies, so the checks compare
        // the rendered composite: the cyan pixel next to the yellow block
        // turns green once yellow spreads under it.
        let boundaryBefore = pixel(session, image, x: 4, y: 4)
        let farBefore = pixel(session, image, x: 9, y: 4)
        check(boundaryBefore != nil && farBefore != nil, "trap: the CMYK composite renders")

        let menu = MainMenu.make()
        NSApp.mainMenu = menu
        guard let imageMenu = menu.item(withTitle: "Image")?.submenu,
              let trapItem = imageMenu.items.first(where: {
                  $0.action == #selector(DocumentWindowController.trap(_:)) }) else {
            return check(false, "trap: Image > Trap… exists")
        }
        check(trapItem.title == "Trap…" && controller.validateMenuItem(trapItem),
              "trap: a CMYK document offers Trap…")
        controller.trap(trapItem)
        wait { controller.window?.attachedSheet != nil }
        guard let window = controller.window, let sheet = window.attachedSheet,
              let content = sheet.contentView,
              let field = descendants(content).compactMap({ $0 as? NSTextField })
                  .first(where: { $0.accessibilityLabel() == "Width" }),
              let button = buttons(sheet.contentView).first(where: { $0.title == "Trap" }) else {
            return check(false, "trap: the Trap sheet has a Width field and Trap button")
        }
        field.stringValue = "2"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification,
                                                            object: field))
        check(button.isEnabled, "trap: width 2 enables the Trap button")
        button.performClick(nil)
        wait { controller.window?.attachedSheet == nil }
        settle(document)

        let undoAfterTrap = try session.undoInfo(image)
        check(undoAfterTrap.undoCount == undoBeforeTrap + 1 && undoAfterTrap.nextUndo == "Trap",
              "trap: a changed trap adds exactly one Undo step named Trap")

        check(pixel(session, image, x: 4, y: 4) != boundaryBefore,
              "trap: the cyan pixel next to the yellow block gains yellow")
        check(pixel(session, image, x: 9, y: 4) == farBefore,
              "trap: the cyan pixel five pixels away is unchanged")
        check(pixel(session, image, x: 1, y: 4) == pixel(session, image, x: 1, y: 2),
              "trap: the yellow block itself is unchanged")

        document.undo()
        settle(document)
        check(pixel(session, image, x: 4, y: 4) == boundaryBefore,
              "trap: Undo restores the boundary pixel")

        let rgbImage = try session.newImage(width: 8, height: 8)
        let rgbDocument = try ImageDocument(session: session, image: rgbImage, name: "Trap RGB refusal")
        owned.append(rgbDocument)
        documents.items.append(rgbDocument)
        check(rgbDocument.trapRefusal() != nil, "trap: an RGB document refuses Trap")
    }
}
