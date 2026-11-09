import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseColorBalance(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(12)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        let pixels = Data((0..<(24 * 16)).flatMap { _ in [UInt8(96), 128, 160, 160] })
        let image = try session.newImage(pixels: ClipboardImage(width: 24, height: 16, pixels: pixels, origin: .zero))
        let otherImage = try session.newImage(width: 12, height: 12)
        let document = try ImageDocument(session: session, image: image, name: "Color Balance A")
        let other = try ImageDocument(session: session, image: otherImage, name: "Color Balance B")
        documents.items += [document, other]
        let controller = DocumentWindowController(document: document), front = DocumentWindowController(document: other)
        controller.showWindow(nil); front.showWindow(nil)
        defer {
            (controller.previewPanel as? ColorBalancePanel)?.cancel()
            for c in [controller, front] {
                c.window?.orderOut(nil)
                var stopped = false; c.canvas.stopRendering { stopped = true }; wait { stopped }
            }
            for doc in [document, other] {
                var closed = false; doc.closeImageWhenDrained { closed = true }; wait { closed }
            }
            documents.items.removeAll { $0 === document || $0 === other }
        }
        func settle() {
            document.inputQueue.sync {}; wait { document.pendingWork == 0 }; spin(0.03)
        }
        let operations = try session.filterOperations()
        NativeFilterCatalog.shared.install(operations)
        guard let operation = operations.first(where: { $0.name == "gimp:color-balance" }),
              let layer = document.activeLayer else { return check(false, "Color Balance and target are available") }
        let original = try session.copyPixels(image, merged: true).pixels
        let otherPixels = try session.copyPixels(otherImage, merged: true).pixels
        let baseline = try session.undoInfo(image).undoCount
        let fakeSession = try session.beginFilter(image: image, drawable: layer, operation: operation.name)
        var writes: [EngineSession.ColorBalanceSettings] = []
        var replies: [@MainActor (Result<Void, Error>) -> Void] = []
        if let controlled = ColorBalancePanel(document: document, filter: fakeSession, settings: .init(), write: { _, value, reply in
            writes.append(value)
            if writes.count == 2 { reply(.failure(ImageDocument.DocumentError.busy)) }
            else { replies.append(reply) }
        }) {
            controlled.cyanRedSlider.doubleValue = 10; controlled.sliderChanged(controlled.cyanRedSlider)
            controlled.magentaGreenSlider.doubleValue = 20; controlled.sliderChanged(controlled.magentaGreenSlider)
            controlled.yellowBlueField.stringValue = "invalid"
            controlled.rangePopup.selectItem(at: 0); controlled.rangeChanged(controlled.rangePopup)
            replies.first?(.success(()))
            check(controlled.yellowBlueField.stringValue == "invalid" && controlled.rangePopup.indexOfSelectedItem == 1,
                  "a local invalid draft remains visible while older native acknowledgements drain")
            controlled.yellowBlueField.stringValue = "5"; controlled.fieldsChanged(controlled.yellowBlueField)
            check(writes.last?.midtones == .init(cyanRed: 0.1, magentaGreen: 0, yellowBlue: 0.05),
                  "a later valid edit cannot resurrect a hidden correction from a refused write")
            controlled.cancel(); settle()
        } else {
            try session.abortFilter(fakeSession)
            check(false, "the controlled acknowledgement fixture opens")
        }
        let pendingSession = try session.beginFilter(image: image, drawable: layer, operation: operation.name)
        writes = []; replies = []
        if let controlled = ColorBalancePanel(document: document, filter: pendingSession, settings: .init(), write: { _, value, reply in
            writes.append(value)
            if writes.count == 2 { reply(.failure(ImageDocument.DocumentError.busy)) }
            else { replies.append(reply) }
        }) {
            controlled.cyanRedSlider.doubleValue = 10; controlled.sliderChanged(controlled.cyanRedSlider)
            controlled.magentaGreenSlider.doubleValue = 20; controlled.sliderChanged(controlled.magentaGreenSlider)
            controlled.rangePopup.selectItem(at: 0); controlled.rangeChanged(controlled.rangePopup)
            controlled.cyanRedSlider.doubleValue = 5; controlled.sliderChanged(controlled.cyanRedSlider)
            check(writes.count == 3 && writes.last?.midtones == .init(cyanRed: 0.1, magentaGreen: 0, yellowBlue: 0) &&
                  writes.last?.shadows.cyanRed == 0.05,
                  "editing another range before an older acknowledgement cannot resubmit a refused correction")
            replies.first?(.success(())); replies.last?(.success(()))
            controlled.cancel(); settle()
        } else {
            try session.abortFilter(pendingSession)
            check(false, "the pending acknowledgement fixture opens")
        }
        func open() -> ColorBalancePanel? {
            controller.openNativeFilter(operation)
            wait { controller.previewPanel != nil && document.pendingWork == 0 }
            return controller.previewPanel as? ColorBalancePanel
        }
        guard let panel = open(), let filter = panel.filter else { return check(false, "Color Balance opens a dedicated editor") }
        check(try session.colorBalanceSettings(filter) == .init() && panel.rangePopup.indexOfSelectedItem == 1,
              "default settings are identity with the Midtones view selected")
        front.window?.makeKeyAndOrderFront(nil)
        panel.cyanRedField.stringValue = "20"; panel.fieldsChanged(panel.cyanRedField); settle()
        var expected = EngineSession.ColorBalanceSettings()
        expected.midtones.cyanRed = 0.2
        check(try session.colorBalanceSettings(filter) == expected, "Midtones edits send the complete nine-value state")
        panel.rangePopup.selectItem(at: 0); panel.rangeChanged(panel.rangePopup); settle()
        check(try session.colorBalanceSettings(filter) == expected && panel.cyanRedField.doubleValue == 0,
              "changing range alone preserves native settings and shows the other range")
        panel.magentaGreenSlider.doubleValue = -10; panel.sliderChanged(panel.magentaGreenSlider); settle()
        expected.shadows.magentaGreen = -0.1
        check(try session.colorBalanceSettings(filter) == expected, "editing Shadows preserves the Midtones correction")
        panel.cyanRedField.stringValue = "invalid"
        panel.rangePopup.selectItem(at: 2); panel.rangeChanged(panel.rangePopup); settle()
        check(try session.colorBalanceSettings(filter) == expected && panel.rangePopup.indexOfSelectedItem == 0
              && panel.cyanRedField.stringValue == "invalid" && panel.lastError != nil,
              "invalid text stays visible and blocks changing range without a native write")
        panel.cyanRedField.stringValue = "0"; panel.fieldsChanged(panel.cyanRedField)
        panel.rangePopup.selectItem(at: 2); panel.rangeChanged(panel.rangePopup)
        panel.yellowBlueField.stringValue = "15"; panel.fieldsChanged(panel.yellowBlueField); settle()
        expected.highlights.yellowBlue = 0.15
        panel.preserveCheckbox.state = .off; panel.preserveChanged(panel.preserveCheckbox); settle()
        expected.preserveLuminosity = false
        check(try session.colorBalanceSettings(filter) == expected, "Highlight and preserve controls retain every other range")
        check(try session.copyPixels(image, merged: true).pixels != original
              && session.copyPixels(otherImage, merged: true).pixels == otherPixels,
              "the preview changes its captured document while another is front")
        panel.cancel(); settle()
        check(try session.copyPixels(image, merged: true).pixels == original && session.undoInfo(image).undoCount == baseline,
              "Cancel restores pixels without adding history")

        guard let accepted = open() else { return check(false, "Color Balance can reopen after Cancel") }
        accepted.cyanRedField.stringValue = "10"; accepted.fieldsChanged(accepted.cyanRedField); settle()
        accepted.window?.makeKeyAndOrderFront(nil)
        accepted.window?.makeFirstResponder(accepted.magentaGreenField)
        if let editor = accepted.magentaGreenField.currentEditor() { editor.string = "-5" }
        else { accepted.magentaGreenField.stringValue = "-5" }
        accepted.commit(); wait { controller.previewPanel == nil && document.pendingWork == 0 }; settle()
        let applied = try session.copyPixels(image, merged: true).pixels
        let effects = try session.effects(on: layer, image: image)
        let history = try session.undoInfo(image).undoCount
        check(applied != original && effects.count == 1 && history == baseline + 1,
              "Apply creates one native effect and Undo step")
        guard let effect = effects.first else { return }
        controller.editEffectParameters(effect.id, on: layer, operationName: operation.name)
        wait { controller.previewPanel != nil && document.pendingWork == 0 }
        guard let editing = controller.previewPanel as? ColorBalancePanel, let editID = editing.filter else {
            return check(false, "the committed effect reopens in its dedicated editor")
        }
        let stored = try session.colorBalanceSettings(editID)
        check(stored.midtones.cyanRed == 0.1 && stored.midtones.magentaGreen == -0.05,
              "Apply commits the last field edit before finishing")
        editing.cyanRedSlider.doubleValue = -20; editing.sliderChanged(editing.cyanRedSlider); settle()
        editing.cancel(); settle()
        check(try session.copyPixels(image, merged: true).pixels == applied && session.undoInfo(image).undoCount == history,
              "existing-effect Cancel preserves committed settings and history")
        try session.undo(image); try document.reload()
        check(try session.copyPixels(image, merged: true).pixels == original, "Undo restores the original image")
        try session.redo(image); try document.reload()
        check(try session.copyPixels(image, merged: true).pixels == applied, "Redo restores the committed color balance")
        let path = work.appendingPathComponent("color-balance-controls.xcf")
        try session.save(image, to: path.path)
        let reopened = try session.openImage(path: path.path)
        check(try session.copyPixels(reopened, merged: true).pixels == applied, "Color Balance survives XCF reopening")
        try session.closeImage(reopened)
    }
}
