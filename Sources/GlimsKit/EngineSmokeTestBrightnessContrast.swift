import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseBrightnessContrast(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(12)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        let source = Data((0..<(24 * 16)).flatMap { _ in [UInt8(64), 128, 192, 128] })
        let image = try session.newImage(pixels: ClipboardImage(width: 24, height: 16, pixels: source, origin: .zero))
        let otherImage = try session.newImage(width: 12, height: 12)
        let document = try ImageDocument(session: session, image: image, name: "Brightness A")
        let other = try ImageDocument(session: session, image: otherImage, name: "Brightness B")
        documents.items += [document, other]
        let controller = DocumentWindowController(document: document), front = DocumentWindowController(document: other)
        controller.showWindow(nil); front.showWindow(nil)
        defer {
            (controller.previewPanel as? BrightnessContrastPanel)?.cancel()
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
        guard let operation = operations.first(where: { $0.name == "gimp:brightness-contrast" }),
              let menu = NSApp.mainMenu, let layer = document.activeLayer else {
            return check(false, "Brightness/Contrast and its captured target are available")
        }
        NativeFilterMenus.install(operations, in: menu)
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        guard let item = items(menu).first(where: { ($0.representedObject as? NativeFilterCommand)?.operation.name == operation.name }),
              let action = item.action else { return check(false, "Brightness/Contrast has an actual menu command") }
        check(controller.validateMenuItem(item) && !item.title.contains("needs"), "only the implemented config editor is enabled")
        let original = try session.copyPixels(image, merged: true).pixels
        let otherPixels = try session.copyPixels(otherImage, merged: true).pixels
        let baseline = try session.undoInfo(image).undoCount
        func openNew() -> BrightnessContrastPanel? {
            NSApp.sendAction(action, to: controller, from: item)
            wait { controller.previewPanel != nil && document.pendingWork == 0 }
            return controller.previewPanel as? BrightnessContrastPanel
        }
        guard let panel = openNew(), let filter = panel.filter else { return check(false, "the dedicated adjustment panel opens") }
        check(try session.brightnessContrastSettings(filter) == .init(), "the initial native pair is an identity")
        front.window?.makeKeyAndOrderFront(nil)
        panel.brightnessField.stringValue = "25"; panel.fieldsChanged(panel.brightnessField); settle()
        check(try session.brightnessContrastSettings(filter) == .init(brightness: 0.25), "percentage fields update the native normalized pair")
        check(try session.copyPixels(image, merged: true).pixels != original
              && session.copyPixels(otherImage, merged: true).pixels == otherPixels,
              "the preview changes its captured image while another document is front")
        panel.brightnessSlider.doubleValue = 30; panel.sliderChanged(panel.brightnessSlider)
        panel.contrastSlider.doubleValue = 20; panel.sliderChanged(panel.contrastSlider); settle()
        check(try session.brightnessContrastSettings(filter) == .init(brightness: 0.3, contrast: 0.2), "successive slider requests preserve both latest values")
        panel.brightnessField.stringValue = "101"; panel.fieldsChanged(panel.brightnessField); settle()
        check(try session.brightnessContrastSettings(filter) == .init(brightness: 0.3, contrast: 0.2)
              && panel.lastError != nil, "an invalid field reports its error and leaves the accepted pair intact")
        panel.cancel(); settle()
        check(try session.copyPixels(image, merged: true).pixels == original && session.undoInfo(image).undoCount == baseline,
              "Cancel restores original pixels and history")

        guard let accepted = openNew() else { return check(false, "a cancelled adjustment can reopen") }
        accepted.contrastField.stringValue = "25"; accepted.fieldsChanged(accepted.contrastField); settle()
        accepted.window?.makeKeyAndOrderFront(nil)
        accepted.window?.makeFirstResponder(accepted.brightnessField)
        if let editor = accepted.brightnessField.currentEditor() { editor.string = "15" }
        else { accepted.brightnessField.stringValue = "15" }
        accepted.commit(); wait { controller.previewPanel == nil && document.pendingWork == 0 }; settle()
        let appliedA = try session.copyPixels(image, merged: true).pixels
        let effectsA = try session.effects(on: layer, image: image)
        check(appliedA != original && effectsA.count == 1 && effectsA.first?.operation == operation.name,
              "Apply commits one real native effect")
        check(try session.undoInfo(image).undoCount == baseline + 1, "a new adjustment makes one Undo step")
        guard let effect = effectsA.first else { return }
        controller.editEffectParameters(effect.id, on: layer, operationName: operation.name)
        wait { controller.previewPanel != nil && document.pendingWork == 0 }
        guard let editing = controller.previewPanel as? BrightnessContrastPanel, let editingID = editing.filter else {
            return check(false, "committed settings open in the dedicated editor")
        }
        check(try session.brightnessContrastSettings(editingID) == .init(brightness: 0.15, contrast: 0.25),
              "Apply commits the last field edit before finishing the preview")
        editing.brightnessSlider.doubleValue = -25; editing.sliderChanged(editing.brightnessSlider); settle()
        editing.cancel(); settle()
        check(try session.copyPixels(image, merged: true).pixels == appliedA && session.undoInfo(image).undoCount == baseline + 1,
              "editing Cancel leaves the committed config and history unchanged")
        controller.editEffectParameters(effect.id, on: layer, operationName: operation.name)
        wait { controller.previewPanel != nil && document.pendingWork == 0 }
        guard let changed = controller.previewPanel as? BrightnessContrastPanel else { return check(false, "an existing effect can reopen") }
        changed.brightnessSlider.doubleValue = -10; changed.sliderChanged(changed.brightnessSlider); settle()
        changed.commit(); wait { controller.previewPanel == nil && document.pendingWork == 0 }; settle()
        let appliedB = try session.copyPixels(image, merged: true).pixels
        let effectsB = try session.effects(on: layer, image: image)
        check(appliedB != appliedA && effectsB.map(\.id) == effectsA.map(\.id), "editing Apply replaces settings without replacing the effect row")
        try session.undo(image); try document.reload()
        check(try session.copyPixels(image, merged: true).pixels == appliedA, "one Undo restores the previous immutable config")
        try session.redo(image); try document.reload()
        check(try session.copyPixels(image, merged: true).pixels == appliedB, "Redo restores the edited config")
        let path = work.appendingPathComponent("brightness-contrast-controls.xcf")
        try session.save(image, to: path.path)
        let reopened = try session.openImage(path: path.path)
        check(try session.copyPixels(reopened, merged: true).pixels == appliedB, "the committed adjustment survives XCF reopening")
        try session.closeImage(reopened)
    }
}
