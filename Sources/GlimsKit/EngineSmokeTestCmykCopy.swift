import AppKit
import CGlimsEngine

@MainActor
extension EngineSmokeTest {
    /// Slot 265 converted copies through the real Image menu path: an RGB
    /// source adopts a CMYK copy through an installed profile, keeps its own
    /// pixels and history, and the CMYK copy converts back to an RGB copy.
    static func exerciseCmykCopy(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin(0.02)
        }
        func pixels(_ document: ImageDocument) throws -> [UInt8] {
            [UInt8](try session.copyPixels(document.image, merged: true).pixels)
        }
        func buttons(_ view: NSView?) -> [NSButton] {
            guard let view else { return [] }
            return ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons($0) }
        }
        /// Runs the controller's own menu action, waits for its sheet to
        /// attach, and confirms it, as the Lab copy smoke does.
        func clickCopy(_ controller: DocumentWindowController, item: NSMenuItem) throws {
            controller.window?.makeKeyAndOrderFront(nil)
            controller.createConvertedCmykCopy(item)
            wait { controller.window?.attachedSheet != nil }
            guard let window = controller.window,
                  let sheet = window.attachedSheet,
                  let button = buttons(sheet.contentView).first(where: { $0.title == "Create Copy" }) else {
                throw NSError(domain: "CmykCopySmoke", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "the confirmation sheet has no Create Copy button"])
            }
            button.performClick(nil)
        }

        guard session.supportsCmykCopy else {
            return check(false, "cmyk-copy: the engine exports slot 265 image_convert_cmyk_copy")
        }
        let profiles = PsdCmykProfileCatalog.discoveredEntries()
        guard !profiles.isEmpty else {
            print("skipped: no CMYK profile installed (supported skip)")
            return
        }

        var owned: [ImageDocument] = []
        var owners: [AppController] = []
        let previousMenu = NSApp.mainMenu
        defer {
            for owner in owners {
                for controller in owner.documents {
                    if let window = controller.window, let sheet = window.attachedSheet {
                        window.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil)
                    }
                    if !controller.closeStarted { controller.closeDiscardingChanges() }
                }
            }
            for document in owned { document.closeImageWhenDrained() }
            wait { owned.allSatisfy { (try? session.info($0.image)) == nil } }
            documents.items.removeAll { document in owned.contains { $0 === document } }
            NSApp.mainMenu = previousMenu
        }

        var bytes: [UInt8] = []
        for _ in 0..<64 { bytes += [80, 140, 200, 255] }
        let image = try session.newImage(pixels: ClipboardImage(width: 8, height: 8,
                                                               pixels: Data(bytes), origin: .zero))
        let source = try ImageDocument(session: session, image: image, name: "CMYK copy source")
        owned.append(source)
        documents.items.append(source)
        let owner = AppController(); owners.append(owner)
        owner.open(source)
        try source.reload()
        settle(source)
        guard let controller = owner.documents.first(where: { $0.imageDocument === source }) else {
            return check(false, "cmyk-copy: the source document has a controller")
        }
        let beforePixels = try pixels(source), beforeUndo = try session.undoInfo(source.image)

        let menu = MainMenu.make()
        NSApp.mainMenu = menu
        guard let imageMenu = menu.item(withTitle: "Image")?.submenu,
              let copyItem = imageMenu.items.first(where: {
                  $0.action == #selector(DocumentWindowController.createConvertedCmykCopy(_:)) }) else {
            return check(false, "cmyk-copy: Image > Create CMYK Copy… exists")
        }
        check(controller.validateMenuItem(copyItem) && copyItem.title == "Create CMYK Copy…",
              "cmyk-copy: an RGB document offers Create CMYK Copy…")
        try clickCopy(controller, item: copyItem)
        wait { owner.documents.count == 2 && !EngineActivity.shared.isBusy }
        guard owner.documents.count == 2 else {
            return check(false, "cmyk-copy: the CMYK copy opens as a new document")
        }
        for item in owner.documents where !owned.contains(where: { $0 === item.imageDocument }) {
            owned.append(item.imageDocument); documents.items.append(item.imageDocument)
        }
        let cmyk = owner.documents.last!.imageDocument
        check(cmyk.image != source.image && cmyk.colorInfo.mode == .cmyk,
              "cmyk-copy: a separate native CMYK document opens")
        check(cmyk.hasUnsavedChanges && cmyk.fileState.nativeURL == nil,
              "cmyk-copy: the copy requires its own Save")
        check(try pixels(source) == beforePixels && session.undoInfo(source.image) == beforeUndo,
              "cmyk-copy: the source keeps its pixels and history")

        // Create RGB Copy… from the CMYK document.
        guard let cmykController = owner.documents.last,
              let backItem = imageMenu.items.first(where: {
                  $0.action == #selector(DocumentWindowController.createConvertedCmykCopy(_:)) }) else {
            return check(false, "cmyk-copy: the CMYK copy has a controller")
        }
        check(cmykController.validateMenuItem(backItem) && backItem.title == "Create RGB Copy…",
              "cmyk-copy: a CMYK document offers Create RGB Copy…")
        try clickCopy(cmykController, item: backItem)
        wait { owner.documents.count == 3 && !EngineActivity.shared.isBusy }
        for item in owner.documents where !owned.contains(where: { $0 === item.imageDocument }) {
            owned.append(item.imageDocument); documents.items.append(item.imageDocument)
        }
        check(owner.documents.count == 3 && owner.documents.last!.imageDocument.colorInfo.mode == .rgb,
              "cmyk-copy: Create RGB Copy… opens a separate RGB document")
    }
}
