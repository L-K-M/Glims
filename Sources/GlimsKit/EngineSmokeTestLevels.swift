import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseLevels(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let limit = Date().addingTimeInterval(12)
            while !condition() && Date() < limit { spin(0.01) }
        }
        let source = Data((0..<(24 * 16)).flatMap { _ in [UInt8(192), 64, 96, 160] })
        let image = try session.newImage(pixels: ClipboardImage(width: 24, height: 16, pixels: source, origin: .zero))
        let otherImage = try session.newImage(width: 12, height: 12)
        let document = try ImageDocument(session: session, image: image, name: "Levels A")
        let other = try ImageDocument(session: session, image: otherImage, name: "Levels B")
        documents.items += [document, other]
        let controller = DocumentWindowController(document: document), front = DocumentWindowController(document: other)
        controller.showWindow(nil); front.showWindow(nil)
        defer {
            (controller.previewPanel as? LevelsPanel)?.cancel()
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
        guard let operation = operations.first(where: { $0.name == "gimp:levels" }),
              let layer = document.activeLayer, let menu = NSApp.mainMenu else {
            return check(false, "Levels and its target are available")
        }
        NativeFilterMenus.install(operations, in: menu)
        guard let adjust = menu.item(withTitle: "Image")?.submenu?.item(withTitle: MainMenu.adjustTitle)?.submenu,
              let item = adjust.item(withTitle: "Levels…"), let action = item.action else {
            return check(false, "Image Adjust exposes the dedicated Levels command")
        }
        let original = try session.copyPixels(image, merged: true).pixels
        let otherPixels = try session.copyPixels(otherImage, merged: true).pixels
        let baseline = try session.undoInfo(image).undoCount
        for text in ["0.31", "invalid"] {
            let filter = try session.beginFilter(image: image, drawable: layer, operation: operation.name)
            var writes: [EngineSession.LevelsSettings] = []
            var firstReply: (@MainActor (Result<Void, Error>) -> Void)?
            guard let panel = LevelsPanel(document: document, filter: filter, settings: .init(), write: { _, value, reply in
                writes.append(value)
                if writes.count == 1 { firstReply = reply }
                else { reply(.failure(ImageDocument.DocumentError.busy)) }
            }) else {
                try session.abortFilter(filter)
                check(false, "the controlled Levels panel accepts valid identity settings")
                continue
            }
            panel.gammaField.stringValue = "2"; panel.fieldsChanged(panel.gammaField)
            panel.highInputField.stringValue = "0.8"; panel.fieldsChanged(panel.highInputField)
            panel.window?.makeKeyAndOrderFront(nil); panel.window?.makeFirstResponder(panel.lowOutputField)
            if let editor = panel.lowOutputField.currentEditor() {
                editor.string = text; firstReply?(.success(()))
                check(panel.lowOutputField.currentEditor()?.string == text,
                      "delayed Levels replies preserve active output text (\(text))")
            } else { check(false, "the Levels output field editor starts") }
            panel.cancel(); settle()
        }
        func open() -> LevelsPanel? {
            NSApp.sendAction(action, to: controller, from: item)
            wait { controller.previewPanel != nil && document.pendingWork == 0 }
            return controller.previewPanel as? LevelsPanel
        }
        guard let panel = open(), let filter = panel.filter else { return check(false, "Levels opens its dedicated form") }
        check(panel.channelPopup.itemTitles == ["Value", "Red", "Green", "Blue", "Alpha"]
              && panel.channelPopup.indexOfSelectedItem == 0 && (try? session.levelsSettings(filter)) == .init(),
              "Levels starts with all25 identity numbers, linear TRC and both clamps off")
        front.window?.makeKeyAndOrderFront(nil)
        panel.gammaField.stringValue = "2"; panel.fieldsChanged(panel.gammaField); settle()
        var expected = EngineSession.LevelsSettings(); expected.value.gamma = 2
        check(try session.levelsSettings(filter) == expected, "Value gamma writes the complete native settings")
        check(try session.copyPixels(image, merged: true).pixels != original
              && session.copyPixels(otherImage, merged: true).pixels == otherPixels,
              "Levels preview changes its captured document while the other image remains exact")
        for index in 1...4 {
            panel.channelPopup.selectItem(at: index); panel.channelChanged(panel.channelPopup)
            panel.lowOutputField.stringValue = String(Double(index) / 20)
            panel.fieldsChanged(panel.lowOutputField); settle()
            switch index {
            case 1: expected.red.lowOutput = 0.05
            case 2: expected.green.lowOutput = 0.1
            case 3: expected.blue.lowOutput = 0.15
            default: expected.alpha.lowOutput = 0.2
            }
            check(try session.levelsSettings(filter) == expected, "channel \(index) retains every other Levels channel")
        }
        panel.trcPopup.selectItem(at: 1)
        panel.clampInputButton.state = .on; panel.clampOutputButton.state = .on
        panel.optionsChanged(panel.trcPopup); settle()
        expected.trc = .nonlinear; expected.clampInput = true; expected.clampOutput = true
        check(try session.levelsSettings(filter) == expected, "TRC and both clamps preserve the whole Levels draft")
        panel.gammaField.stringValue = "0.01"
        panel.channelPopup.selectItem(at: 0); panel.channelChanged(panel.channelPopup); settle()
        check(panel.channelPopup.indexOfSelectedItem == 4 && panel.gammaField.stringValue == "0.01"
              && panel.lastError != nil && (try? session.levelsSettings(filter)) == expected,
              "invalid gamma preserves its text and channel without a native write")
        panel.cancel(); settle()
        check(try session.copyPixels(image, merged: true).pixels == original && session.undoInfo(image).undoCount == baseline,
              "Levels Cancel restores exact original pixels and history")
        guard let accepted = open() else { return check(false, "a cancelled Levels form reopens") }
        accepted.gammaField.stringValue = "2"; accepted.fieldsChanged(accepted.gammaField); settle()
        accepted.window?.makeKeyAndOrderFront(nil); accepted.window?.makeFirstResponder(accepted.lowOutputField)
        if let editor = accepted.lowOutputField.currentEditor() { editor.string = "0.125" }
        else { accepted.lowOutputField.stringValue = "0.125" }
        accepted.commit(); wait { controller.previewPanel == nil && document.pendingWork == 0 }; settle()
        let applied = try session.copyPixels(image, merged: true).pixels
        let effects = try session.effects(on: layer, image: image)
        var appliedSettings = EngineSession.LevelsSettings()
        appliedSettings.value.gamma = 2; appliedSettings.value.lowOutput = 0.125
        check(applied != original && effects.count == 1 && effects[0].operation == operation.name,
              "Apply commits one native Levels effect")
        check(try session.undoInfo(image).undoCount == baseline + 1, "Levels Apply creates one Undo step")
        guard let effect = effects.first else { return }
        controller.editEffectParameters(effect.id, on: layer, operationName: operation.name)
        wait { controller.previewPanel != nil && document.pendingWork == 0 }
        guard let editing = controller.previewPanel as? LevelsPanel, let editingFilter = editing.filter else {
            return check(false, "the existing Levels effect reopens")
        }
        check(try session.levelsSettings(editingFilter) == appliedSettings,
              "Levels Apply includes the active final field and existing settings reopen exactly")
        editing.lowInputField.stringValue = "0.8"; editing.highInputField.stringValue = "0.2"
        editing.fieldsChanged(editing.highInputField); settle()
        var inverted = appliedSettings; inverted.value.lowInput = 0.8; inverted.value.highInput = 0.2
        check(try session.levelsSettings(editingFilter) == inverted, "inverted input endpoints remain valid and unsorted")
        editing.lowInputField.stringValue = "0.5"; editing.highInputField.stringValue = "0.5"
        editing.fieldsChanged(editing.highInputField); settle()
        var equal = appliedSettings; equal.value.lowInput = 0.5; equal.value.highInput = 0.5
        check(try session.levelsSettings(editingFilter) == equal, "equal input endpoints remain valid")
        editing.cancel(); settle()
        check(try session.copyPixels(image, merged: true).pixels == applied && session.undoInfo(image).undoCount == baseline + 1,
              "existing Levels Cancel preserves committed configuration and history")
        try session.undo(image); try document.reload()
        check(try session.copyPixels(image, merged: true).pixels == original, "Undo restores original Levels pixels")
        try session.redo(image); try document.reload()
        check(try session.copyPixels(image, merged: true).pixels == applied, "Redo restores Levels pixels")
        let path = work.appendingPathComponent("levels-controls.xcf")
        try session.save(image, to: path.path)
        let reopened = try session.openImage(path: path.path)
        let rows = try session.layers(reopened)
        guard let reopenedLayer = rows.first, let reopenedEffect = try session.effects(on: reopenedLayer.id, image: reopened).first else {
            try session.closeImage(reopened); return check(false, "the saved Levels effect reloads")
        }
        let reopenedFilter = try session.beginEditingEffect(reopenedEffect.id, on: reopenedLayer.id, image: reopened)
        check(try session.levelsSettings(reopenedFilter) == appliedSettings
              && session.copyPixels(reopened, merged: true).pixels == applied,
              "XCF retains all Levels settings and visible result")
        try session.abortFilter(reopenedFilter); try session.closeImage(reopened)
    }
}
