import AppKit
import RigiUI

// MARK: - GLIMS_SMOKE_CASE=brush-palette-sync

@MainActor
extension EngineSmokeTest {
    /// Checks the displayed controls, including a live AppKit field editor;
    /// model-only preset checks cannot detect a stale palette or lost draft.
    static func exerciseBrushPaletteSync(_ session: EngineSession, documents: DocumentList) throws {
        func views<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
            guard let root else { return [] }
            return (root as? T).map { [$0] } ?? root.subviews.flatMap { views($0, as: type) }
        }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        let state = ToolState.shared
        let originalTool = state.current
        let originalBrush = state.brush(for: .paintbrush)
        let originalForeground = state.foreground
        let originalBackground = state.background
        let originalSource = state.cloneSource
        let originalStore = state.brushStore
        let suite = "ch.lkmc.Glims.smoke.brush-palette-sync.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        state.brushStore = BrushSelectionStore(defaults: defaults)
        defer {
            state.brushStore = originalStore
            state.update(.paintbrush) { $0 = originalBrush }
            state.foreground = originalForeground
            state.background = originalBackground
            state.cloneSource = originalSource
            state.select(originalTool)
            defaults.removePersistentDomain(forName: suite)
        }
        state.select(.paintbrush)
        state.setBrushResource(nil, for: .paintbrush)
        state.update(.paintbrush) {
            $0.size = 10; $0.opacity = 0.8; $0.hardness = 0.5; $0.pressureSize = true
        }
        state.foreground = .blue
        state.notifyChange()

        let image = try session.newImage(width: 64, height: 48)
        let document = try ImageDocument(session: session, image: image, name: "Brush palette synchronization")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        let options = ToolOptionsPaletteController()
        options.retarget(to: document)
        let optionsWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 330, height: 360),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        optionsWindow.isReleasedWhenClosed = false
        optionsWindow.contentView = options.view
        optionsWindow.orderFront(nil)
        let tools = ToolsPaletteController()
        let toolsWindow = NSWindow(contentRect: NSRect(x: 450, y: 100, width: 80, height: 330),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        toolsWindow.isReleasedWhenClosed = false
        toolsWindow.contentView = tools.view
        toolsWindow.orderFront(nil)
        let store = PaintToolPresetStore(defaults: defaults)
        let panel = PaintToolPresetPanelController(toolState: state, store: store)
        defer {
            optionsWindow.makeFirstResponder(nil)
            panel.closePanel(nil)
            optionsWindow.close()
            toolsWindow.close()
            controller.window?.close()
            documents.items.removeAll { $0 === document }
            var closed = false
            document.closeImageWhenDrained { closed = true }
            wait { closed }
            check(closed && (try? session.info(image)) == nil,
                  "the brush-palette image closes before engine shutdown")
        }
        func field(_ label: String) -> NSTextField? {
            views(options.view, as: NSTextField.self).first {
                $0.isEditable && $0.accessibilityLabel() == "\(label) value"
            }
        }
        func displayed(_ label: String, equals value: Double) -> Bool {
            guard let field = field(label) else { return false }
            return abs(field.doubleValue - value) < 0.001
        }
        func observeSize(_ stage: String) {
            let sizeField = field("Size")
            let value = views(options.view, as: ClassicValueSlider.self).first { $0.accessibilityTitle == "Size" }?.value
            print("OBS Size \(stage): model=\(state.brush(for: .paintbrush).size), value=\(value ?? -1), "
                + "text=\(sizeField?.stringValue ?? "<missing>"), double=\(sizeField?.doubleValue ?? -1), "
                + "editor=\(sizeField?.currentEditor()?.string ?? "<none>"), "
                + "first=\(String(describing: optionsWindow.firstResponder)), key=\(optionsWindow.isKeyWindow)")
        }
        func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
            guard let window = controller.window,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                              timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                              characters: text, charactersIgnoringModifiers: text,
                                              isARepeat: false, keyCode: code) else {
                check(false, "the brush shortcut event can be constructed")
                return
            }
            window.makeFirstResponder(controller.canvas)
            controller.canvas.keyDown(with: event)
        }
        check(displayed("Size", equals: 10) && displayed("Opacity", equals: 80),
              "actual Tool Options starts with the committed brush values")
        let untouchedEditor = field("Size")?.currentEditor()
        check(untouchedEditor != nil, "the initial Size field has an untouched actual editor")
        observeSize("initial")
        key("]", code: 30)
        observeSize("right bracket")
        check(displayed("Size", equals: state.brush(for: .paintbrush).size),
              "canvas right-bracket immediately refreshes the displayed Size")
        check(untouchedEditor != nil && field("Size")?.currentEditor() === untouchedEditor
                && optionsWindow.firstResponder === untouchedEditor,
              "refreshing an untouched focused Size field preserves its editor and focus")
        key("5", code: 23)
        check(displayed("Opacity", equals: 50),
              "canvas digit immediately refreshes the displayed Opacity")
        key("]", code: 30, flags: .shift)
        check(displayed("Hardness", equals: 60),
              "canvas Shift-bracket immediately refreshes the displayed Hardness")

        // The same tool and nil Default resource cannot cause a tool/resource
        // switch to conceal missing numeric and checkbox synchronization.
        var savedBrush = state.brush(for: .paintbrush)
        savedBrush.size = 33; savedBrush.opacity = 0.25
        savedBrush.hardness = 0.2; savedBrush.pressureSize = false
        let preset = try store.create(tool: .paintbrush, name: "Red preset",
            settings: PaintToolPresetControls.captureSettings(from: savedBrush),
            brushResource: nil, foregroundColor: .init(red: 1, green: 0, blue: 0))
        let capturedBeforeApply = state.brush(for: .paintbrush)
        let pair = views(tools.view, as: ClassicColorPair.self).first
        check(pair?.foreground == NSColor.blue, "the actual foreground swatch starts blue")
        panel.open()
        let table = views(panel.window?.contentView, as: NSTableView.self).first
        table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let apply = views(panel.window?.contentView, as: NSButton.self).first {
            $0.accessibilityLabel() == "Apply selected preset"
        }
        check(apply != nil && panel.selectedPresetID == preset.id, "the actual preset Apply control is selected")
        apply?.performClick(nil)
        observeSize("preset 33")
        check(displayed("Size", equals: 33) && displayed("Opacity", equals: 25)
                && displayed("Hardness", equals: 20),
              "same-tool same-resource preset Apply immediately refreshes displayed brush values")
        check(views(options.view, as: NSButton.self).first { $0.title == "Pen pressure sets size" }?.state == .off,
              "same-resource preset Apply immediately refreshes the displayed pressure checkbox")
        let foreground = pair?.foreground.usingColorSpace(.sRGB)
        check(foreground != nil && foreground!.redComponent > 0.99 && foreground!.blueComponent < 0.01,
              "preset Apply immediately refreshes the actual foreground swatch from blue to red")
        check(state.foreground.usingColorSpace(.sRGB)?.redComponent == 1
                && state.brush(for: .paintbrush).resource == nil
                && capturedBeforeApply.size != state.brush(for: .paintbrush).size
                && capturedBeforeApply.opacity == 0.5,
              "preset synchronization preserves committed color, resource and the immutable previous snapshot")
        panel.closePanel(nil)

        // The preset domain already accepts native sizes above the former
        // palette limit. Show the actual value, without changing its color.
        var largeSettings = preset.settings
        largeSettings.size = 1000
        try store.replace(id: preset.id, settings: largeSettings, brushResource: nil, foregroundColor: nil)
        state.foreground = .blue
        state.notifyChange()
        panel.open()
        table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        apply?.performClick(nil)
        observeSize("preset 1000")
        check(state.brush(for: .paintbrush).size == 1000 && displayed("Size", equals: 1000),
              "a valid 1000-pixel preset displays its actual size without clamping to 500")
        check(state.foreground == NSColor.blue && pair?.foreground == NSColor.blue
                && preset.settings.size == 33 && preset.foregroundColor != nil,
              "a colorless preset preserves foreground and the earlier preset remains immutable")
        panel.closePanel(nil)
        key("[", code: 33)
        observeSize("left bracket from 1000")
        check(state.brush(for: .paintbrush).size == 800 && displayed("Size", equals: 800),
              "left bracket from a 1000-pixel preset decreases size to 800 and refreshes the display")
        state.update(.paintbrush) { $0.size = 1000 }
        key("]", code: 30)
        observeSize("right bracket from 1000")
        check(state.brush(for: .paintbrush).size == 1250 && displayed("Size", equals: 1250),
              "right bracket from 1000 increases size to 1250 within the native preset domain")
        state.update(.paintbrush) { $0.size = 33 }

        // External model and resource notifications must preserve the exact
        // live editor and draft. Ending it commits through Rigi's real parser.
        guard let sizeField = field("Size") else {
            check(false, "the Size field exists for the live-draft scenario")
            return
        }
        optionsWindow.makeKeyAndOrderFront(nil)
        check(optionsWindow.makeFirstResponder(sizeField), "the actual Size field accepts editing")
        guard let editor = sizeField.currentEditor() else {
            check(false, "the actual Size field has an AppKit field editor")
            return
        }
        editor.string = "47"
        state.update(.paintbrush) { $0.size = 72; $0.opacity = 0.6 }
        check(sizeField.currentEditor() === editor && optionsWindow.firstResponder === editor && editor.string == "47",
              "external numeric updates preserve the active Size draft and focus")
        check(displayed("Opacity", equals: 60), "other brush values refresh while Size has an active draft")
        // A different retained identity exercises the old presentation-rebuild
        // path without opening the chooser or making native resource calls.
        let changedIdentity = EngineSession.ResourceIdentity(name: "Unresolved smoke draft brush", collection: nil, isInternal: false)
        state.setBrushResource(changedIdentity, for: .paintbrush)
        check(sizeField.isDescendant(of: options.view) && sizeField.currentEditor() === editor
                && optionsWindow.firstResponder === editor && editor.string == "47",
              "an unrelated resource presentation update preserves the active draft view and focus")
        optionsWindow.makeFirstResponder(nil)
        spin()
        check(state.brush(for: .paintbrush).size == 47 && displayed("Size", equals: 47),
              "ending the active draft commits and reconciles the displayed Size")

        // Invalid input reports no Rigi change; the deferred refresh must
        // still reconcile the latest external committed value on editing end.
        if let invalidField = field("Size"), optionsWindow.makeFirstResponder(invalidField),
           let invalidEditor = invalidField.currentEditor() {
            invalidEditor.string = "invalid"
            state.update(.paintbrush) { $0.size = 81 }
            check(invalidEditor.string == "invalid", "external state does not overwrite an invalid active draft")
            optionsWindow.makeFirstResponder(nil)
            spin()
            check(state.brush(for: .paintbrush).size == 81 && displayed("Size", equals: 81),
                  "ending an invalid draft reconciles the latest committed Size")
        } else {
            check(false, "the Size field can start an invalid-draft edit")
        }

        if let partialField = field("Size"), optionsWindow.makeFirstResponder(partialField),
           let partialEditor = partialField.currentEditor() {
            partialEditor.string = "81."
            state.update(.paintbrush) { $0.size = 91 }
            check(partialEditor.string == "81." && partialField.currentEditor() === partialEditor
                    && optionsWindow.firstResponder === partialEditor,
                  "a numeric-equivalent partial draft survives external updates with its focus")
            partialEditor.string = "81.00"
            state.update(.paintbrush) { $0.size = 92 }
            check(partialEditor.string == "81.00" && partialField.currentEditor() === partialEditor,
                  "an equivalent value with unfinished formatting stays an exact draft")
            partialEditor.string = "83"
            optionsWindow.makeFirstResponder(nil)
            spin()
            check(state.brush(for: .paintbrush).size == 83 && displayed("Size", equals: 83),
                  "completing a preserved partial draft commits through the normal numeric control")
        } else {
            check(false, "the Size field can start a partial-draft edit")
        }

        // Rigi suppresses onChange when parsed input equals its earlier
        // control value. The user's explicit commit must still win over an
        // external model change received while that exact draft was kept.
        state.update(.paintbrush) { $0.size = 81 }
        if let equalField = field("Size"), optionsWindow.makeFirstResponder(equalField),
           let equalEditor = equalField.currentEditor() {
            equalEditor.string = "81.00"
            state.update(.paintbrush) { $0.size = 92 }
            check(equalEditor.string == "81.00" && equalField.currentEditor() === equalEditor
                    && optionsWindow.firstResponder === equalEditor,
                  "an equal-value draft keeps its exact text and focus during an external change")
            optionsWindow.makeFirstResponder(nil)
            spin()
            check(state.brush(for: .paintbrush).size == 81 && displayed("Size", equals: 81),
                  "ending the explicit 81.00 draft commits 81 over the external 92 value")
        } else {
            check(false, "the Size field can start an equal-value commit edit")
        }
    }
}
