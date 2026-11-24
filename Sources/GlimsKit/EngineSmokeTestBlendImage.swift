import AppKit

// MARK: - GLIMS_SMOKE_CASE=blend-image

@MainActor
extension EngineSmokeTest {
    /// GLIMS_SMOKE_CASE=blend-image (also in the full run): Image > Blend
    /// With Image and Image > Blend Channels. Two 8x8 RGB documents open
    /// the real utility panels; Multiply blends document B into A as one
    /// named undo step and Undo restores the exact bytes; Blend Channels
    /// adds a saved channel named Alpha 1 and then creates a new grayscale
    /// document through the app's adoption handler.
    static func exerciseBlendImage(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && document.recorder.pendingCount == 0
                && !document.recorder.isReplaying && !EngineActivity.shared.isBusy }
            spin(0.02)
        }
        func pixels(_ image: Int32) throws -> [UInt8] {
            [UInt8](try session.copyPixels(image, merged: true).pixels)
        }
        func solid(_ color: [UInt8]) -> [UInt8] {
            (0..<(8 * 8 * 4)).map { color[$0 % 4] }
        }

        var owned: [ImageDocument] = []
        var controllers: [DocumentWindowController] = []
        var errors: [String] = []
        func fixture(_ name: String, color: [UInt8]) throws -> (ImageDocument, DocumentWindowController) {
            let image = try session.newImage(pixels: ClipboardImage(width: 8, height: 8,
                                                                    pixels: Data(solid(color)),
                                                                    origin: .zero))
            let document = try ImageDocument(session: session, image: image, name: name)
            document.onError = { errors.append($0) }
            // The app wires this in AppController.open; the smoke adopts the
            // NEW_IMAGE result itself so the check observes the same path.
            document.blendChannelsHandler = { _, result in
                guard let adopted = try? ImageDocument(session: session, image: result,
                                                       name: "Untitled") else { return }
                owned.append(adopted)
                documents.items.append(adopted)
            }
            owned.append(document)
            documents.items.append(document)
            let controller = DocumentWindowController(document: document)
            controller.showWindow(nil)
            controllers.append(controller)
            try document.reload()
            settle(document)
            return (document, controller)
        }
        defer {
            for controller in controllers {
                controller.blendImagePanel?.cancel()
                controller.blendChannelsPanel?.cancel()
                controller.colorRangePanel?.cancel()
                if let window = controller.window, let sheet = window.attachedSheet {
                    window.endSheet(sheet)
                }
                controller.window?.orderOut(nil)
                var stopped = false
                controller.canvas.stopRendering { stopped = true }
                while !stopped { spin(0.01) }
            }
            for document in owned { document.closeImageWhenDrained() }
            wait { owned.allSatisfy { (try? session.info($0.image)) == nil } }
            documents.items.removeAll { document in owned.contains { $0 === document } }
        }

        let menu = MainMenu.make()
        NSApp.mainMenu = menu
        guard let imageMenu = menu.item(withTitle: "Image")?.submenu,
              let blendItem = imageMenu.item(withTitle: "Blend With Image…"),
              let channelsItem = imageMenu.item(withTitle: "Blend Channels…") else {
            return check(false, "Image > Blend With Image… and Blend Channels… exist")
        }
        check(blendItem.action == #selector(DocumentWindowController.blendWithImage(_:)),
              "Blend With Image… carries its action")
        check(channelsItem.action == #selector(DocumentWindowController.blendChannels(_:)),
              "Blend Channels… carries its action")

        let colorA: [UInt8] = [200, 100, 50, 255]
        let colorB: [UInt8] = [100, 150, 200, 255]
        let (documentA, controllerA) = try fixture("Blend A", color: colorA)
        let (documentB, controllerB) = try fixture("Blend B", color: colorB)
        documentA.selectLayer(documentA.layers.first?.id ?? 0)
        settle(documentA)
        let originalA = try pixels(documentA.image)

        // Blend With Image: document B over A at Multiply and 100%.
        controllerA.window?.makeKeyAndOrderFront(nil)
        spin(0.05)
        controllerA.blendWithImage(nil)
        wait { controllerA.blendImagePanel != nil }
        guard let panel = controllerA.blendImagePanel else {
            return check(false, "the Blend With Image panel opens")
        }
        panel.selectSource(document: documentB)
        panel.selectMode(.multiply)
        panel.setOpacity(1)
        let undoBeforeBlend = try session.undoInfo(documentA.image).undoCount
        panel.commit()
        wait { controllerA.blendImagePanel == nil }
        settle(documentA)

        let infoAfterBlend = try session.undoInfo(documentA.image)
        check(infoAfterBlend.undoCount == undoBeforeBlend + 1
              && infoAfterBlend.nextUndo == "Blend With Image",
              "OK applies one named Blend With Image undo step (\(infoAfterBlend.nextUndo); errors: \(errors))")
        let expectedMultiply = [UInt8(200 * 100 / 255), UInt8(100 * 150 / 255), UInt8(50 * 200 / 255), 255]
        let blendedPixel = try EngineSmokeTest.pixel(session, documentA.image, x: 3, y: 3) ?? []
        check(blendedPixel.count == 4
              && (0..<3).allSatisfy({ abs(Int(blendedPixel[$0]) - Int(expectedMultiply[$0])) <= 1 })
              && blendedPixel[3] == 255,
              "Multiply blends B into A (\(blendedPixel) vs \(expectedMultiply))")

        documentA.undo()
        settle(documentA)
        check(try pixels(documentA.image) == originalA, "Undo restores the Blend With Image source")

        // Blend Channels: red of A with green of B, Normal, a new channel.
        controllerA.blendChannels(nil)
        wait { controllerA.blendChannelsPanel != nil }
        guard let channelsPanel = controllerA.blendChannelsPanel else {
            return check(false, "the Blend Channels panel opens")
        }
        channelsPanel.selectFirst(document: documentA, layer: 0, kind: .red)
        channelsPanel.selectSecond(document: documentB, layer: 0, kind: .green)
        channelsPanel.selectMode(.normal)
        channelsPanel.setOpacity(1)
        channelsPanel.selectResult(.newChannel("Alpha 1"))
        let undoBeforeChannel = try session.undoInfo(documentA.image).undoCount
        channelsPanel.commit()
        wait { controllerA.blendChannelsPanel == nil }
        settle(documentA)

        let channelNames = try session.channels(documentA.image).map(\.name)
        let infoAfterChannel = try session.undoInfo(documentA.image)
        check(channelNames.contains("Alpha 1"),
              "Blend Channels adds the named channel (\(channelNames))")
        check(infoAfterChannel.undoCount == undoBeforeChannel + 1
              && infoAfterChannel.nextUndo == "Blend Channels",
              "the channel result is one named Blend Channels undo step (\(infoAfterChannel.nextUndo))")

        // Blend Channels: the same inputs into a new grayscale document.
        let documentCount = documents.items.count
        controllerA.blendChannels(nil)
        wait { controllerA.blendChannelsPanel != nil }
        guard let newImagePanel = controllerA.blendChannelsPanel else {
            return check(false, "the Blend Channels panel reopens")
        }
        newImagePanel.selectFirst(document: documentA, layer: 0, kind: .red)
        newImagePanel.selectSecond(document: documentB, layer: 0, kind: .green)
        newImagePanel.selectMode(.normal)
        newImagePanel.setOpacity(1)
        newImagePanel.selectResult(.newImage)
        let undoBeforeNewImage = try session.undoInfo(documentA.image).undoCount
        newImagePanel.commit()
        wait { documents.items.count > documentCount }
        settle(documentA)
        let newest = documents.items.last
        check(newest != nil && newest !== documentA, "New Document adopts the blend result as a document")
        guard let adopted = newest, adopted !== documentA else { return }
        try adopted.reload()
        check(adopted.colorInfo.mode == .grayscale && adopted.info.width == 8 && adopted.info.height == 8
              && adopted.layers.count == 1,
              "the new document is an 8x8 grayscale image with one layer (\(adopted.colorInfo.mode.title) \(adopted.info.width)x\(adopted.info.height))")
        check(try session.undoInfo(documentA.image).undoCount == undoBeforeNewImage,
              "a New Document result leaves the source document's history alone")

        // Two open documents may share a name, and a document can close
        // while a panel is open: each document keeps its own item, and a
        // closing one is never blended and leaves the pop-ups.
        let (twin, _) = try fixture("Blend B", color: colorA)
        controllerA.window?.makeKeyAndOrderFront(nil)
        spin(0.05)
        controllerA.blendChannels(nil)
        wait { controllerA.blendChannelsPanel != nil }
        guard let listChannelsPanel = controllerA.blendChannelsPanel else {
            return check(false, "the Blend Channels panel opens with a same-named document")
        }
        check(listChannelsPanel.secondItemTitles.count == listChannelsPanel.secondDocumentChoices.count
              && listChannelsPanel.secondDocumentChoices.contains { $0 === twin },
              "Blend Channels offers both documents named Blend B (\(listChannelsPanel.secondItemTitles))")
        listChannelsPanel.cancel()
        wait { controllerA.blendChannelsPanel == nil }

        controllerA.blendWithImage(nil)
        wait { controllerA.blendImagePanel != nil }
        guard let listPanel = controllerA.blendImagePanel else {
            return check(false, "the Blend With Image panel opens with a same-named document")
        }
        let twinCount = listPanel.sourceDocumentChoices.filter { $0 === twin || $0 === documentB }.count
        check(listPanel.sourceItemTitles.count == listPanel.sourceDocumentChoices.count && twinCount == 2,
              "Blend With Image offers both documents named Blend B (\(listPanel.sourceItemTitles))")
        listPanel.selectSource(document: twin)
        check(listPanel.settings.source.image == twin.image,
              "choosing the second Blend B blends that document")
        twin.beginClosing()
        check(listPanel.settings.source.kind == .none && listPanel.settings.validationError != nil,
              "a closing source document is never blended")
        listPanel.documentsChanged()
        check(!listPanel.sourceDocumentChoices.contains { $0 === twin }
              && listPanel.sourceItemTitles.count == listPanel.sourceDocumentChoices.count,
              "a closing document leaves the source pop-up (\(listPanel.sourceItemTitles))")
        listPanel.cancel()
        wait { controllerA.blendImagePanel == nil }
    }
}
