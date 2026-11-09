import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseHueSaturation(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let limit = Date().addingTimeInterval(12)
            while !condition() && Date() < limit { spin(0.01) }
        }
        let source = Data((0..<(24 * 16)).flatMap { _ in [UInt8(192), 64, 96, 160] })
        let image = try session.newImage(pixels: ClipboardImage(width: 24, height: 16, pixels: source, origin: .zero))
        let otherImage = try session.newImage(width: 12, height: 12)
        let document = try ImageDocument(session: session, image: image, name: "Hue A")
        let other = try ImageDocument(session: session, image: otherImage, name: "Hue B")
        documents.items += [document, other]
        let controller = DocumentWindowController(document: document), front = DocumentWindowController(document: other)
        controller.showWindow(nil); front.showWindow(nil)
        defer {
            (controller.previewPanel as? HueSaturationPanel)?.cancel()
            for c in [controller, front] {
                c.window?.orderOut(nil)
                var stopped = false; c.canvas.stopRendering { stopped = true }; wait { stopped }
            }
            for doc in [document, other] {
                var closed = false; doc.closeImageWhenDrained { closed = true }; wait { closed }
            }
            documents.items.removeAll { $0 === document || $0 === other }
        }
        func settle() { document.inputQueue.sync {}; wait { document.pendingWork == 0 }; spin(0.03) }
        let operations = try session.filterOperations()
        NativeFilterCatalog.shared.install(operations)
        guard let operation = operations.first(where: { $0.name == "gimp:hue-saturation" }),
              let layer = document.activeLayer, let menu = NSApp.mainMenu else {
            return check(false, "Hue/Saturation and its target are available")
        }
        NativeFilterMenus.install(operations, in: menu)
        guard let adjust = menu.item(withTitle: "Image")?.submenu?.item(withTitle: MainMenu.adjustTitle)?.submenu,
              let item = adjust.item(withTitle: "Hue/Saturation…"), let action = item.action else {
            return check(false, "Image Adjust exposes the dedicated Hue/Saturation command")
        }
        let original = try session.copyPixels(image, merged: true).pixels
        let otherPixels = try session.copyPixels(otherImage, merged: true).pixels
        let baseline = try session.undoInfo(image).undoCount
        for text in ["31", "invalid"] {
            let filter = try session.beginFilter(image: image, drawable: layer, operation: operation.name)
            var writes: [EngineSession.HueSaturationSettings] = []
            var firstReply: (@MainActor (Result<Void, Error>) -> Void)?
            guard let panel = HueSaturationPanel(document: document, filter: filter, settings: .init(), write: { _, value, reply in
                writes.append(value)
                if writes.count == 1 { firstReply = reply }
                else { reply(.failure(ImageDocument.DocumentError.busy)) }
            }) else { try session.abortFilter(filter); continue }
            panel.hueSlider.doubleValue = 18; panel.sliderChanged(panel.hueSlider)
            panel.saturationSlider.doubleValue = 20; panel.sliderChanged(panel.saturationSlider)
            panel.window?.makeKeyAndOrderFront(nil); panel.window?.makeFirstResponder(panel.overlapField)
            if let editor = panel.overlapField.currentEditor() {
                editor.string = text; firstReply?(.success(()))
                check(panel.overlapField.currentEditor()?.string == text,
                      "delayed Hue/Saturation replies preserve active overlap text (\(text))")
            } else { check(false, "the overlap field editor starts") }
            panel.cancel(); settle()
        }
        func open() -> HueSaturationPanel? {
            NSApp.sendAction(action, to: controller, from: item)
            wait { controller.previewPanel != nil && document.pendingWork == 0 }
            return controller.previewPanel as? HueSaturationPanel
        }
        guard let panel = open(), let filter = panel.filter else { return check(false, "Hue/Saturation opens its dedicated form") }
        check(panel.rangePopup.itemTitles == ["Master", "Red", "Yellow", "Green", "Cyan", "Blue", "Magenta"]
              && panel.rangePopup.indexOfSelectedItem == 0 && (try? session.hueSaturationSettings(filter)) == .init(),
              "the editor starts with all22 default values and the Master view")
        front.window?.makeKeyAndOrderFront(nil)
        panel.hueField.stringValue = "60"; panel.fieldsChanged(panel.hueField); settle()
        var expected = EngineSession.HueSaturationSettings()
        expected.master.hue = 60.0 / 180.0
        check(try session.hueSaturationSettings(filter) == expected, "hue degrees write the normalized Master correction")
        check(try session.copyPixels(image, merged: true).pixels != original
              && session.copyPixels(otherImage, merged: true).pixels == otherPixels,
              "the preview changes its captured image while the other document remains exact")
        for index in 1...6 {
            panel.rangePopup.selectItem(at: index); panel.rangeChanged(panel.rangePopup)
            panel.saturationField.stringValue = String(index * 5); panel.fieldsChanged(panel.saturationField); settle()
            let value = Double(index * 5) / 100
            switch index {
            case 1: expected.red.saturation = value
            case 2: expected.yellow.saturation = value
            case 3: expected.green.saturation = value
            case 4: expected.cyan.saturation = value
            case 5: expected.blue.saturation = value
            default: expected.magenta.saturation = value
            }
            check(try session.hueSaturationSettings(filter) == expected,
                  "range \(index) edits retain every other named range")
        }
        panel.overlapField.stringValue = "25"; panel.fieldsChanged(panel.overlapField); settle()
        expected.overlap = 0.25
        check(try session.hueSaturationSettings(filter) == expected, "global overlap preserves the complete seven-range draft")
        panel.overlapField.stringValue = "101"
        panel.rangePopup.selectItem(at: 0); panel.rangeChanged(panel.rangePopup); settle()
        check(panel.rangePopup.indexOfSelectedItem == 6 && panel.overlapField.stringValue == "101"
              && panel.lastError != nil && (try? session.hueSaturationSettings(filter)) == expected,
              "invalid overlap keeps its draft and the previous range without a native write")
        panel.cancel(); settle()
        check(try session.copyPixels(image, merged: true).pixels == original && session.undoInfo(image).undoCount == baseline,
              "Cancel restores exact original pixels and history")
        guard let accepted = open() else { return check(false, "a cancelled Hue/Saturation form reopens") }
        accepted.hueSlider.doubleValue = 90; accepted.sliderChanged(accepted.hueSlider)
        accepted.overlapSlider.doubleValue = 50; accepted.sliderChanged(accepted.overlapSlider); settle()
        accepted.window?.makeKeyAndOrderFront(nil); accepted.window?.makeFirstResponder(accepted.saturationField)
        if let editor = accepted.saturationField.currentEditor() { editor.string = "25" }
        else { accepted.saturationField.stringValue = "25" }
        accepted.commit(); wait { controller.previewPanel == nil && document.pendingWork == 0 }; settle()
        let applied = try session.copyPixels(image, merged: true).pixels
        let effects = try session.effects(on: layer, image: image)
        var appliedSettings = EngineSession.HueSaturationSettings(overlap: 0.5)
        appliedSettings.master.hue = 0.5; appliedSettings.master.saturation = 0.25
        check(applied != original && effects.count == 1 && effects[0].operation == operation.name,
              "Apply commits one real native Hue/Saturation effect")
        check(try session.undoInfo(image).undoCount == baseline + 1, "Hue/Saturation Apply creates one Undo step")
        guard let effect = effects.first else { return }
        controller.editEffectParameters(effect.id, on: layer, operationName: operation.name)
        wait { controller.previewPanel != nil && document.pendingWork == 0 }
        guard let editing = controller.previewPanel as? HueSaturationPanel, let editingFilter = editing.filter else {
            return check(false, "the existing effect reopens in its typed form")
        }
        check(try session.hueSaturationSettings(editingFilter) == appliedSettings,
              "Apply includes the final field edit and existing settings reopen exactly")
        editing.rangePopup.selectItem(at: 5); editing.rangeChanged(editing.rangePopup)
        editing.hueField.stringValue = "-60"; editing.fieldsChanged(editing.hueField); settle()
        editing.cancel(); settle()
        check(try session.copyPixels(image, merged: true).pixels == applied && session.undoInfo(image).undoCount == baseline + 1,
              "existing-effect Cancel preserves the committed configuration and history")
        try session.undo(image); try document.reload()
        check(try session.copyPixels(image, merged: true).pixels == original, "Undo restores the original image")
        try session.redo(image); try document.reload()
        check(try session.copyPixels(image, merged: true).pixels == applied, "Redo restores Hue/Saturation pixels")
        let path = work.appendingPathComponent("hue-saturation-controls.xcf")
        try session.save(image, to: path.path)
        let reopened = try session.openImage(path: path.path)
        let rows = try session.layers(reopened)
        guard let reopenedLayer = rows.first, let reopenedEffect = try session.effects(on: reopenedLayer.id, image: reopened).first else {
            try session.closeImage(reopened); return check(false, "the saved effect reloads")
        }
        let reopenedFilter = try session.beginEditingEffect(reopenedEffect.id, on: reopenedLayer.id, image: reopened)
        check(try session.hueSaturationSettings(reopenedFilter) == appliedSettings
              && session.copyPixels(reopened, merged: true).pixels == applied,
              "XCF retains the complete settings and visible result")
        try session.abortFilter(reopenedFilter); try session.closeImage(reopened)
    }
}
