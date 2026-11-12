import AppKit

@MainActor
extension EngineSmokeTest {
    /// The owned `glims:selective-color` compact editor: percent display
    /// over native -1...1 writes, range switching that neither writes
    /// nor adds history, the Relative/Absolute method popup and the
    /// shared Apply/Cancel preview lifecycle.
    static func exerciseSelectiveColor(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(12)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        // Reds, greens and blues with partial alpha, so selective edits
        // move color while the alpha bytes stay exact.
        var bytes = Data()
        for _ in 0..<8 {
            for x in 0..<9 {
                let rgb: [UInt8] = [[200, 40, 40], [40, 180, 60], [60, 80, 220]][x / 3]
                bytes.append(contentsOf: [rgb[0], rgb[1], rgb[2], x.isMultiple(of: 2) ? 128 : 255])
            }
        }
        let image = try session.newImage(pixels: ClipboardImage(width: 9, height: 8, pixels: bytes, origin: .zero))
        let otherImage = try session.newImage(width: 8, height: 8)
        let document = try ImageDocument(session: session, image: image, name: "Selective A")
        let other = try ImageDocument(session: session, image: otherImage, name: "Selective B")
        documents.items += [document, other]
        let controller = DocumentWindowController(document: document), front = DocumentWindowController(document: other)
        controller.showWindow(nil); front.showWindow(nil)
        defer {
            (controller.previewPanel as? NativeFilterPanel)?.cancel()
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
        func alpha(_ pixels: Data) -> [UInt8] {
            stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
        }
        let operations = try session.filterOperations()
        NativeFilterCatalog.shared.install(operations)
        guard let menu = NSApp.mainMenu else { return check(false, "the application menu exists") }
        NativeFilterMenus.install(operations, in: menu)
        guard let adjust = menu.item(withTitle: "Image")?.submenu?.item(withTitle: MainMenu.adjustTitle)?.submenu,
              let item = adjust.item(withTitle: "Selective Color…"),
              let command = item.representedObject as? NativeFilterCommand, let action = item.action else {
            return check(false, "Image ▸ Adjust offers Selective Color from the catalog")
        }
        check(command.operation.name == SelectiveColorPanel.operation && controller.validateMenuItem(item),
              "Selective Color routes a supported owned operation")
        guard let layer = document.activeLayer else { return check(false, "a target layer exists") }
        let original = try session.copyPixels(image, merged: true).pixels
        let baseline = try session.undoInfo(image).undoCount

        NSApp.sendAction(action, to: controller, from: item)
        wait { controller.previewPanel != nil && document.pendingWork == 0 }
        guard let panel = controller.previewPanel as? SelectiveColorPanel, let filter = panel.filter else {
            return check(false, "Selective Color opens its compact editor")
        }
        check(panel.colorsPopup.indexOfSelectedItem == 0 && panel.methodPopup.indexOfSelectedItem == 0
              && panel.channelRow(.red, .cyan)?.field.stringValue == "0"
              && (try? session.filterProperty(filter, "relative")) == .boolean(true),
              "the loaded default is Relative with the Reds range selected")

        if let directory = ProcessInfo.processInfo.environment["GLIMS_SMOKE_ARTIFACT_DIR"],
           let view = panel.window?.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("selective-color-panel.png"))
        }
        check((panel.window?.frame.height ?? .infinity) < 360,
              "the compact form fits all controls in a short window")
        // Percent display, native write: the field shows 25 for 0.25.
        guard let redCyan = panel.channelRow(.red, .cyan) else {
            return check(false, "the Reds Cyan row exists")
        }
        redCyan.field.stringValue = "25"
        redCyan.commitField(); settle()
        check((try? session.filterProperty(filter, "red-cyan")) == .number(0.25)
              && redCyan.field.stringValue == "25" && redCyan.value == 0.25,
              "a typed percentage writes the native -1...1 value")
        check(try session.undoInfo(image).undoCount == baseline, "a preview write adds no Undo step")

        // Switching the viewed range ends the field edit but writes and
        // records nothing; hidden ranges keep their engine-side values.
        panel.colorsPopup.selectItem(at: SelectiveColorPanel.ColorRange.blue.ordinalIndex)
        panel.colorsChanged(panel.colorsPopup); settle()
        check(panel.selectedRange == .blue
              && (try? session.filterProperty(filter, "red-cyan")) == .number(0.25)
              && (try? session.filterProperty(filter, "blue-cyan")) == .number(0)
              && (try? session.filterProperty(filter, "green-magenta")) == .number(0),
              "changing the viewed range writes nothing and keeps every range's values")
        check(try session.undoInfo(image).undoCount == baseline, "changing the viewed range adds no history")
        let windowSize = panel.window?.frame.size

        // A second range's edit is independent of the first's.
        guard let blueMagenta = panel.channelRow(.blue, .magenta),
              let hiddenRedCyan = panel.channelRow(.red, .cyan) else {
            return check(false, "the bound rows of hidden ranges exist")
        }
        blueMagenta.field.stringValue = "-30"
        blueMagenta.commitField(); settle()
        check((try? session.filterProperty(filter, "blue-magenta")) == .number(-0.3)
              && (try? session.filterProperty(filter, "red-cyan")) == .number(0.25),
              "editing another range preserves the first range's correction")
        panel.colorsPopup.selectItem(at: 0); panel.colorsChanged(panel.colorsPopup); settle()
        check(hiddenRedCyan.field.stringValue == "25" && hiddenRedCyan.value == 0.25
              && blueMagenta.value == -0.3 && panel.window?.frame.size == windowSize,
              "switching back shows retained values in a same-sized window")

        // An in-flight peer acknowledgement never clobbers the text the
        // user is still editing in the same property's field.
        panel.window?.makeKeyAndOrderFront(nil)
        panel.window?.makeFirstResponder(redCyan.field)
        if let editor = redCyan.field.currentEditor() {
            editor.string = "77"
            panel.setProperty("red-yellow", .number(0.1)); settle()
            check(redCyan.field.currentEditor()?.string == "77",
                  "a peer acknowledgement preserves the active field draft")
            panel.window?.endEditing(for: nil); settle()
        } else { check(false, "the Cyan field editor starts") }
        check((try? session.filterProperty(filter, "red-cyan")) == .number(0.77)
              && (try? session.filterProperty(filter, "red-yellow")) == .number(0.1),
              "the ended draft commits its percentage alongside the peer write")

        // Method writes the relative boolean; alpha stays exact through
        // every preview write.
        panel.methodPopup.selectItem(at: 1); panel.methodChanged(panel.methodPopup); settle()
        check((try? session.filterProperty(filter, "relative")) == .boolean(false),
              "Absolute writes the native relative flag off")
        let preview = try session.copyPixels(image, merged: true).pixels
        check(preview != original && alpha(preview) == alpha(original),
              "selective preview changes colors while alpha stays exact")
        panel.cancel(); settle()
        check(try session.copyPixels(image, merged: true).pixels == original
              && session.undoInfo(image).undoCount == baseline,
              "Cancel restores pixels without adding history")

        // Apply keeps the preview as one Undo step and one effect.
        NSApp.sendAction(action, to: controller, from: item)
        wait { controller.previewPanel != nil && document.pendingWork == 0 }
        guard let accepted = controller.previewPanel as? SelectiveColorPanel else {
            return check(false, "Selective Color reopens after Cancel")
        }
        accepted.channelRow(.red, .cyan)?.field.stringValue = "50"
        accepted.channelRow(.red, .cyan)?.commitField(); settle()
        accepted.apply()
        wait { controller.previewPanel == nil && document.pendingWork == 0 }; settle()
        let applied = try session.copyPixels(image, merged: true).pixels
        let effects = try session.effects(on: layer, image: image)
        let history = try session.undoInfo(image).undoCount
        check(applied != original && alpha(applied) == alpha(original)
              && effects.count == 1 && history == baseline + 1,
              "Apply commits one effect as one Undo step with exact alpha")
        guard let effect = effects.first else { return }

        // The committed effect reopens in the same editor through the
        // New Adjustment Layer path's shared routing.
        controller.editEffectParameters(effect.id, on: layer, operationName: command.operation.name)
        wait { controller.previewPanel != nil && document.pendingWork == 0 }
        guard let editing = controller.previewPanel as? SelectiveColorPanel, let editID = editing.filter else {
            return check(false, "the committed effect reopens in its compact editor")
        }
        check((try? session.filterProperty(editID, "red-cyan")) == .number(0.5)
              && editing.channelRow(.red, .cyan)?.value == 0.5
              && editing.channelRow(.red, .cyan)?.field.stringValue == "50"
              && editing.methodPopup.indexOfSelectedItem == 0,
              "the loaded effect shows its stored values as percentages")
        editing.cancel(); settle()
        check(try session.copyPixels(image, merged: true).pixels == applied
              && session.undoInfo(image).undoCount == history,
              "effect-edit Cancel preserves committed settings and history")
        try session.undo(image); try document.reload()
        check(try session.copyPixels(image, merged: true).pixels == original,
              "Undo restores the original image")
    }
}

private extension SelectiveColorPanel.ColorRange {
    var ordinalIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
