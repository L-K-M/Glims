import AppKit

/// Public-facade state available without creating a channel or otherwise
/// editing the selection: bounds/outline, pixels, targets, tree and history.
private struct ToolHintNativeState: Equatable {
    let info: EngineSession.ImageInfo
    let layers: [EngineSession.Layer]
    let selected: [Int32]
    let channels: [EngineSession.Channel]
    let selectedChannels: [Int32]
    let selection: CGRect?
    let outline: [EngineSession.Segment]
    let raw: Data
    let composite: Data
    let fullRender: Data
    let history: EngineSession.UndoInfo

    init(_ session: EngineSession, _ image: Int32) throws {
        info = try session.info(image)
        layers = try session.layers(image)
        selected = try session.selectedLayers(image)
        channels = try session.channels(image)
        selectedChannels = try session.selectedItems(.channel, image: image)
        selection = try session.selectionBounds(image: image)
        outline = try session.selectionOutline(image: image)
        raw = try session.copyPixels(image, merged: false).pixels
        composite = try session.copyPixels(image, merged: true).pixels
        guard let rendered = try session.render(image, scale: 1,
            area: CGRect(x: 0, y: 0, width: Int(info.width), height: Int(info.height))).dataProvider?.data else {
            throw ImageDocument.DocumentError.busy
        }
        fullRender = rendered as Data
        history = try session.undoInfo(image)
    }
}

@MainActor
extension EngineSmokeTest {
    /// Uses only pre-existing event methods/statusBar.message, so this fixture
    /// can be overlaid on old Main to witness absent live hints independently.
    static func exerciseToolHints(_ session: EngineSession, documents: DocumentList) throws {
        let savedTool = ToolState.shared.current
        let savedForeground = ToolState.shared.foreground
        let savedPencil = ToolState.shared.brush(for: .pencil)
        var ownedImages: [Int32] = [], ownedDocuments: [ImageDocument] = []
        var controllers: [DocumentWindowController] = []
        var gates: [DispatchSemaphore] = []
        var completed = false
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition(), Date() < deadline { spin(0.01) }
            if !condition() { check(false, "tool hints timed out waiting for counted work") }
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        defer {
            gates.forEach { $0.signal() }
            ToolState.shared.foreground = savedForeground
            ToolState.shared.update(.pencil) { $0 = savedPencil }
            ToolState.shared.select(savedTool)
            var stoppedAll = true
            for controller in controllers {
                controller.window?.orderOut(nil)
                var stopped = false
                controller.canvas.stopRendering { stopped = true }
                wait { stopped }
                stoppedAll = stoppedAll && stopped
                controller.window?.close()
            }
            check(stoppedAll, "tool hint teardown drains owned renderers")
            ownedDocuments.forEach { $0.closeImageWhenDrained() }
            for image in ownedImages where !ownedDocuments.contains(where: { $0.image == image }) {
                if !gone(image) { try? session.closeImage(image) }
            }
            wait { ownedDocuments.allSatisfy { $0.pendingWork == 0 } && !EngineActivity.shared.isBusy }
            wait { ownedImages.allSatisfy { gone($0) } }
            check(ownedImages.allSatisfy { gone($0) }, "tool hint teardown closes every owned native image")
            check(controllers.allSatisfy { $0.window?.attachedSheet == nil }, "tool hint teardown leaves no owned dialog")
            documents.items.removeAll { candidate in ownedDocuments.contains { $0 === candidate } }
            check(completed, "tool hints complete all dedicated acceptance scenarios")
        }
        func fixture(_ name: String, red: UInt8) throws -> (ImageDocument, DocumentWindowController) {
            var rgba: [UInt8] = []
            for index in 0..<(32 * 24) {
                rgba.append(red)
                rgba.append(UInt8((index * 7) % 256))
                rgba.append(UInt8((index * 19) % 256))
                rgba.append(255)
            }
            let bytes = Data(rgba)
            let image = try session.newImage(pixels: ClipboardImage(width: 32, height: 24, pixels: bytes, origin: .zero))
            ownedImages.append(image)
            try session.select(.rectangle(CGRect(x: 3, y: 4, width: 11, height: 8)), image: image)
            let document = try ImageDocument(session: session, image: image, name: name)
            ownedDocuments.append(document); documents.items.append(document)
            let controller = DocumentWindowController(document: document)
            controllers.append(controller); controller.showWindow(nil)
            return (document, controller)
        }
        let (a, owner) = try fixture("Hint A", red: 31)
        let (b, other) = try fixture("Hint B", red: 209)
        wait { a.pendingWork == 0 && b.pendingWork == 0 }
        let beforeA = try ToolHintNativeState(session, a.image), beforeB = try ToolHintNativeState(session, b.image)
        func key(_ controller: DocumentWindowController, type: NSEvent.EventType, code: UInt16,
                 text: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: controller.window?.windowNumber ?? 0, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)
        }
        func flags(_ controller: DocumentWindowController, _ flags: NSEvent.ModifierFlags) {
            guard let event = key(controller, type: .flagsChanged, code: 56, flags: flags) else {
                return check(false, "tool hint fixture constructs a modifier event")
            }
            controller.canvas.flagsChanged(with: event)
        }
        func press(_ controller: DocumentWindowController, type: NSEvent.EventType, code: UInt16,
                   text: String = "", flags: NSEvent.ModifierFlags = []) {
            guard let event = key(controller, type: type, code: code, text: text, flags: flags) else {
                return check(false, "tool hint fixture constructs a key event")
            }
            if type == .keyDown { controller.canvas.keyDown(with: event) }
            else { controller.canvas.keyUp(with: event) }
        }
        func pointer(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) {
            let location = owner.canvas.convert(CGPoint(x: 5 * owner.canvas.scale, y: 6 * owner.canvas.scale), to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags,
                timestamp: 0, windowNumber: owner.window?.windowNumber ?? 0, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1) else {
                return check(false, "tool hint fixture constructs a pointer event")
            }
            if type == .leftMouseDown { owner.canvas.mouseDown(with: event) }
            else { owner.canvas.mouseUp(with: event) }
        }
        ToolState.shared.select(.paintbrush)
        flags(owner, [])
        check(owner.statusBar.message.hasPrefix("Drag to apply brush."), "stationary tool selection shows its live affordance (old Main RED)")
        check(owner.statusBar.message.contains("32 × 24 px") && owner.statusBar.message.contains("Undo"),
              "idle status retains image dimensions, layers and Undo after its useful hint")
        let otherIdle = other.statusBar.message
        flags(owner, .option)
        check(owner.statusBar.message.hasPrefix("Option-click or drag to sample the foreground color."), "stationary Option shows color sampling")
        check(other.statusBar.message == otherIdle, "modifier events on A leave B's status untouched")
        flags(owner, [.command, .option])
        check(owner.statusBar.message.hasPrefix("Drag a layer or guide."), "Command Move outranks paint Option sampling")
        // Cmd-Space is reserved by the system. Hold plain Space first, then
        // add modifiers, matching the temporary-tool precedence contract.
        flags(owner, [])
        press(owner, type: .keyDown, code: 49, text: " ")
        flags(owner, [.command, .option])
        check(owner.statusBar.message.hasPrefix("Drag to pan the view."), "Space Hand outranks Command Move")
        press(owner, type: .keyUp, code: 49, text: " ", flags: [.command, .option])
        check(owner.statusBar.message.hasPrefix("Drag a layer or guide."), "Space release restores held Command Move")
        flags(owner, [])
        check(owner.statusBar.message.hasPrefix("Drag to apply brush."), "modifier release restores the selected tool without pointer movement")
        press(owner, type: .keyDown, code: 58)
        check(owner.statusBar.message.hasPrefix("Option-click or drag to sample"), "Option key-down refreshes held-key sampling even without a flags event")
        press(owner, type: .keyUp, code: 58)
        check(owner.statusBar.message.hasPrefix("Drag to apply brush."), "Option key-up clears the held-key sampling hint")
        press(owner, type: .keyDown, code: 55)
        check(owner.statusBar.message.hasPrefix("Drag a layer or guide."), "Command key-down refreshes temporary Move without pointer movement")
        press(owner, type: .keyUp, code: 55)
        check(owner.statusBar.message.hasPrefix("Drag to apply brush."), "Command key-up restores the selected tool hint")
        ToolState.shared.select(.clone); flags(owner, .option)
        check(owner.statusBar.message.hasPrefix("Option-click to set the clone source."), "Clone advertises source selection rather than color sampling")
        ToolState.shared.select(.heal)
        check(owner.statusBar.message.hasPrefix("Option-click to set the heal source."), "Heal tool observer refreshes the stationary source affordance")
        ToolState.shared.select(.eraser)
        check(owner.statusBar.message.hasPrefix("Option-click or drag to sample"), "Eraser uses the actual ordinary-paint Option sample behavior")
        ToolState.shared.select(.zoom)
        check(owner.statusBar.message.hasPrefix("Click to zoom out."), "Zoom tool reflects already held Option")
        flags(owner, [])
        check(owner.statusBar.message.hasPrefix("Click to zoom in."), "Zoom modifier release refreshes while stationary")
        ToolState.shared.select(.rectangleSelect); flags(owner, .shift)
        check(owner.statusBar.message.hasPrefix("Add to the selection with rectangle."), "before press Shift means Add selection")
        flags(owner, .option)
        check(owner.statusBar.message.hasPrefix("Subtract from the selection with rectangle."), "before press Option means Subtract selection")
        flags(owner, [.shift, .option])
        check(owner.statusBar.message.hasPrefix("Intersect the selection with rectangle."), "before press Shift-Option means Intersect selection")
        flags(owner, .shift)
        pointer(.leftMouseDown, flags: .shift)
        check(owner.statusBar.message.hasPrefix("Constrained rectangle."), "after press the captured rectangle switches Shift to geometry constraint")
        flags(owner, .option)
        check(owner.statusBar.message.hasPrefix("Drag a rectangle from its center."), "during drag Option means center rather than Subtract")
        ToolState.shared.select(.paintbrush); flags(owner, [.shift, .option])
        check(owner.statusBar.message.hasPrefix("Constrained rectangle from its center."), "drag hint keeps the captured tool despite global tool selection changes")
        press(owner, type: .keyDown, code: 53, text: "\u{1b}")
        pointer(.leftMouseUp)
        check(owner.statusBar.message == "Selection cancelled.", "pointer/key trailing hint refresh preserves explicit cancellation feedback")
        flags(owner, [])
        check(owner.statusBar.message.hasPrefix("Drag to apply brush."), "a new context refresh returns from action feedback to idle hints")
        check(try ToolHintNativeState(session, a.image) == beforeA && ToolHintNativeState(session, b.image) == beforeB,
              "modifier/tool/cancelled-drag events preserve both complete facade state snapshots")

        a.onError?("Latched refusal for A")
        flags(owner, .option); ToolState.shared.select(.lasso)
        check(owner.statusBar.message == "Latched refusal for A", "modifier and tool observer hints never clear A's latched refusal")
        check(other.statusBar.message.hasPrefix("Select freehand area."), "a global tool selection still updates unblocked B independently")
        let gate = DispatchSemaphore(value: 0); gates.append(gate)
        var activityDone = false
        let admitted = EngineActivity.shared.perform(label: "Hint busy fixture", work: { gate.wait() }, completion: { activityDone = true })
        let busyText = other.statusBar.message
        flags(other, [.command, .option]); ToolState.shared.select(.crop)
        check(admitted && busyText == "Hint busy fixture…" && other.statusBar.message == busyText,
              "modifier/tool refresh preserves exact existing engine activity text")
        check(owner.statusBar.message == "Latched refusal for A", "another document's busy hint refresh cannot replace A's refusal")
        other.showProgress(.init(fraction: 0.5, text: "Plug-in stage 7 of 9"))
        flags(other, .option); ToolState.shared.select(.text)
        check(other.statusBar.message == "Plug-in stage 7 of 9", "live hints preserve exact native progress text above an activity label")
        gate.signal(); wait { activityDone && !EngineActivity.shared.isBusy }
        other.showProgress(nil)
        check(other.statusBar.message.hasPrefix("Click to add or edit text."), "idle hints return after progress and activity finish")
        check(owner.statusBar.message == "Latched refusal for A", "ending B progress still preserves A's error latch")
        ToolState.shared.select(.rectangleSelect); flags(owner, [])
        pointer(.leftMouseDown)
        press(owner, type: .keyDown, code: 53, text: "\u{1b}")
        pointer(.leftMouseUp)
        check(owner.statusBar.message == "Selection cancelled.", "an actual new cancellation action can replace its own document's prior refusal")
        check(try ToolHintNativeState(session, a.image) == beforeA && ToolHintNativeState(session, b.image) == beforeB,
              "error, busy and progress presentation leaves native pixels, selection, targets, tree, dirty state and history unchanged")
        // Real modifier flags must not survive a same-window field-editor
        // detour. Each case has a fresh document and independent native pixel
        // oracle, so a failed first case cannot contaminate the next case.
        let focusCases: [(String, NSEvent.ModifierFlags, UInt16)] = [
            ("Option", .option, 58), ("Command", .command, 55)
        ]
        for (name, modifier, code) in focusCases {
            let (focusedDocument, focusedOwner) = try fixture("Hint focus \(name)", red: 31)
            guard let window = focusedOwner.window else {
                return check(false, "the \(name) focus fixture has an owning window")
            }
            let canvas = focusedOwner.canvas
            let field = NSTextField(string: "")
            field.frame = NSRect(x: 0, y: 0, width: 160, height: 22)
            window.contentView?.addSubview(field)
            window.makeFirstResponder(canvas)
            let keyWindowBefore = window.isKeyWindow
            let targetLayers = try session.layers(focusedDocument.image)
            let targets = try session.selectedLayers(focusedDocument.image)
            let beforeUndo = try session.undoInfo(focusedDocument.image).undoCount

            // Literal seed/configuration, not ToolHintPolicy or a controller's
            // computed brush, supplies the expected native pencil pixels.
            var seed: [UInt8] = []
            for index in 0..<(32 * 24) {
                seed += [31, UInt8((index * 7) % 256), UInt8((index * 19) % 256), 255]
            }
            let expected = try session.newImage(pixels: ClipboardImage(width: 32, height: 24,
                pixels: Data(seed), origin: .zero))
            ownedImages.append(expected)
            try session.select(.rectangle(CGRect(x: 3, y: 4, width: 11, height: 8)), image: expected)
            guard let expectedTarget = try session.layers(expected).first?.id else {
                return check(false, "the \(name) independent native oracle has a paint target")
            }
            var brush = EngineSession.Brush()
            brush.tool = .pencil; brush.size = 5; brush.opacity = 1
            brush.pressureSize = false; brush.hardness = 1
            let stroke = try session.beginStroke(image: expected, drawable: expectedTarget, brush: brush,
                first: .init(x: 8, y: 8, pressure: 1, timeMilliseconds: 1000))
            try session.endStroke(stroke)
            let expectedPixels = try ToolHintNativeState(session, expected).fullRender
            ToolState.shared.foreground = .black
            ToolState.shared.update(.pencil) { $0 = brush }
            ToolState.shared.select(.pencil)

            guard let down = key(focusedOwner, type: .flagsChanged, code: code, flags: modifier),
                  let release = key(focusedOwner, type: .flagsChanged, code: code, flags: []) else {
                return check(false, "the \(name) field-focus modifier events can be constructed")
            }
            canvas.flagsChanged(with: down)
            window.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else {
                return check(false, "the \(name) focus fixture creates a real field editor")
            }
            check(window.firstResponder === editor && window.isKeyWindow == keyWindowBefore,
                  "\(name) release moves keyboard focus within the same window")
            editor.insertText("modifier release here", replacementRange: NSRange(location: NSNotFound, length: 0))
            // Deliver release to its actual field first responder. Sending it
            // back to the canvas would mask the lost-release regression.
            window.firstResponder?.flagsChanged(with: release)
            check(window.firstResponder === editor && editor.string == "modifier release here",
                  "the field owns \(name) release and preserves its typing draft")
            window.makeFirstResponder(canvas)
            check(window.firstResponder === canvas && focusedOwner.statusBar.message.hasPrefix("Drag to apply pencil."),
                  "return from a field clears the stale \(name) temporary-tool hint")
            func paintPointer(_ type: NSEvent.EventType) throws {
                guard let event = NSEvent.mouseEvent(with: type,
                    location: canvas.convert(CGPoint(x: 8 * canvas.scale, y: 8 * canvas.scale), to: nil),
                    modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1) else {
                    throw NSError(domain: "ToolHintFocusFixture", code: 1)
                }
                if type == .leftMouseDown { canvas.mouseDown(with: event) }
                else { canvas.mouseUp(with: event) }
            }
            try paintPointer(.leftMouseDown)
            check(focusedDocument.strokeIsActive,
                  "a modifier-free press after field \(name) release accepts paint, not a temporary tool")
            try paintPointer(.leftMouseUp)
            focusedDocument.inputQueue.sync {}
            wait { focusedDocument.pendingWork == 0 && !EngineActivity.shared.isBusy }
            let after = try ToolHintNativeState(session, focusedDocument.image)
            check(!focusedDocument.strokeIsActive && after.fullRender == expectedPixels
                    && after.history.undoCount == beforeUndo + 1,
                  "\(name) field-focus recovery paints independent expected pixels as one native Undo")
            check(after.layers == targetLayers && after.selected == targets && field.stringValue == "modifier release here",
                  "\(name) focus recovery preserves the captured layer target and field text")
            field.removeFromSuperview()
        }
        completed = true
    }
}
