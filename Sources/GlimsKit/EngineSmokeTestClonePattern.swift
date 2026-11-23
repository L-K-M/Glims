import AppKit

/// Clone's Pattern source through Tool Options, the pattern chooser and
/// real canvas strokes: no Option-click is needed, an unchosen pattern is
/// refused, the chooser writes the pattern Edit ▸ Fill shares, and the
/// Image source keeps its Option-click requirement.
extension EngineSmokeTest {
    static func exerciseClonePattern(_ session: EngineSession, documents: DocumentList) throws {
        guard session.supportsPaintOptions else {
            print("     clone pattern: this engine cannot clone from a pattern; skipped")
            return
        }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        let image = try session.newImage(width: 160, height: 100)
        let document = try ImageDocument(session: session, image: image, name: "Clone Pattern")
        var errors: [String] = []
        document.onError = { errors.append($0) }
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        let state = ToolState.shared
        let oldTool = state.current, oldFrom = state.cloneFrom, oldSource = state.cloneSource
        let oldAligned = state.cloneAlignment.isAligned, oldPattern = state.patternStore.identity
        let oldClone = state.brush(for: .clone)
        defer {
            ClonePatternChooser.shared.close()
            state.update(.clone) { $0 = oldClone }
            state.cloneFrom = oldFrom; state.cloneSource = oldSource
            state.cloneAlignment.isAligned = oldAligned
            state.patternStore.set(oldPattern)
            state.select(oldTool)
            controller.window?.orderOut(nil)
            var stopped = false; controller.canvas.stopRendering { stopped = true }; wait { stopped }
            var closed = false; document.closeImageWhenDrained { closed = true }; wait { closed }
            documents.items.removeAll { $0 === document }
        }
        guard let window = controller.window else { return check(false, "clone pattern: the window exists") }
        window.contentView?.layoutSubtreeIfNeeded()
        let canvas = controller.canvas

        func settle() {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }; spin(0.03)
        }
        func gesture(_ points: [CGPoint]) {
            guard let first = points.first, let last = points.last else { return }
            let steps = [(NSEvent.EventType.leftMouseDown, first)]
                + points.dropFirst().map { (NSEvent.EventType.leftMouseDragged, $0) }
                + [(NSEvent.EventType.leftMouseUp, last)]
            for (type, point) in steps {
                let location = canvas.convert(CGPoint(x: point.x * canvas.scale, y: point.y * canvas.scale), to: nil)
                guard let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                    return check(false, "clone pattern: events construct")
                }
                switch type {
                case .leftMouseDown: canvas.mouseDown(with: event)
                case .leftMouseDragged: canvas.mouseDragged(with: event)
                default: canvas.mouseUp(with: event)
                }
            }
            settle()
        }
        func line(_ y: Double) -> [CGPoint] {
            (0...24).map { CGPoint(x: 10 + 140 * Double($0) / 24, y: y) }
        }
        /// Columns of row `y` that are no longer white.
        func changed(_ y: Int) -> Int {
            (0..<160).filter { x in (pixel(session, image, x: x, y: y)?.prefix(3).contains { $0 < 250 }) ?? false }.count
        }

        state.select(.clone)
        state.cloneSource = nil
        state.cloneAlignment.isAligned = true
        state.patternStore.set(nil)
        state.update(.clone) { $0.clearPaintOptions(); $0.size = 9; $0.opacity = 1; $0.resource = nil; $0.pressureSize = false }
        let options = ToolOptionsPaletteController()
        options.retarget(to: document)
        let sourceMenu = { descendant(of: options.view, as: NSPopUpButton.self) { $0.identifier?.rawValue == "clone-source" } }
        let patternButton = { descendant(of: options.view, as: NSButton.self) { $0.identifier?.rawValue == "clone-pattern" } }
        check(sourceMenu()?.itemTitles == ["Image", "Pattern"] && sourceMenu()?.indexOfSelectedItem == 0
                && patternButton() == nil,
              "clone pattern: Clone's Source menu offers Image and Pattern, Image first, without a pattern row")
        if let menu = sourceMenu() {
            menu.selectItem(at: 1)
            menu.sendAction(menu.action, to: menu.target)
        }
        check(state.cloneFrom == .pattern && patternButton()?.title == "Choose…" && patternButton()?.isEnabled == true,
              "clone pattern: choosing Pattern shows an enabled pattern button with no pattern chosen")

        // With no pattern chosen a press is refused before any paint.
        let steps = try session.undoInfo(image).undoCount
        gesture(line(20))
        check(try changed(20) == 0 && (try session.undoInfo(image).undoCount) == steps,
              "clone pattern: a press with no pattern paints nothing and adds no step")

        // The chooser lists the catalog; Cancel writes nothing.
        let catalog = try DispatchQueue.global(qos: .userInitiated).sync { try session.resources(.pattern) }
        patternButton()?.performClick(nil)
        guard let panel = ClonePatternChooser.shared.openPanel else {
            return check(false, "clone pattern: the pattern button opens the chooser")
        }
        wait { if case .ready = panel.picker.model.state { return true }; return false }
        check(panel.picker.model.rows.count == catalog.count && catalog.count > 1,
              "clone pattern: the chooser lists the whole pattern catalog (\(panel.picker.model.rows.count) of \(catalog.count))")
        // A shipped, opaque pattern; the clipboard's pattern can be empty.
        let rows = panel.picker.model.rows
        guard let first = rows.first(where: { $0.name == "Pine" }) ?? rows.first(where: { !$0.name.hasPrefix("Clipboard") }),
              let second = rows.first(where: { $0.id != first.id }) else {
            return check(false, "clone pattern: the catalog has two patterns to choose between")
        }
        panel.picker.model.select(second.id)
        panel.window?.performClose(nil)
        check(!ClonePatternChooser.shared.isOpen && state.patternStore.identity == nil,
              "clone pattern: closing the chooser writes no pattern")

        // Choose writes the shared pattern and the button names it.
        patternButton()?.performClick(nil)
        guard let chooser = ClonePatternChooser.shared.openPanel else {
            return check(false, "clone pattern: the chooser opens again")
        }
        wait { if case .ready = chooser.picker.model.state { return true }; return false }
        chooser.picker.model.select(first.id)
        chooser.choose(nil)
        check(!ClonePatternChooser.shared.isOpen && state.patternStore.identity == first.identity
                && PatternFillStore.shared.identity == first.identity && patternButton()?.title == first.name,
              "clone pattern: Choose sets the pattern Fill shares and the button shows \(first.name)")
        check(state.brush(for: .clone).clonePattern == .init(resource: first.identity, aligned: true)
                && state.brush(for: .clone).source == nil && state.brush(for: .heal).clonePattern == nil,
              "clone pattern: the Clone brush carries the aligned pattern; Heal does not")

        // A stroke needs no Option-click and is one step.
        gesture(line(30))
        let painted = changed(30)
        check(try painted > 100 && (try session.undoInfo(image).undoCount) == steps + 1,
              "clone pattern: a pattern stroke paints without a source point as one step (\(painted) columns)")
        state.cloneAlignment.isAligned = false
        check(state.brush(for: .clone).clonePattern?.aligned == false,
              "clone pattern: clearing Aligned makes the pattern start at each stroke")

        // Back to Image: the Option-click requirement returns.
        if let menu = sourceMenu() {
            menu.selectItem(at: 0)
            menu.sendAction(menu.action, to: menu.target)
        }
        gesture(line(60))
        check(try state.cloneFrom == .image && patternButton() == nil && changed(60) == 0
                && (try session.undoInfo(image).undoCount) == steps + 1,
              "clone pattern: the Image source still needs an Option-click before it paints")
        check(errors.isEmpty, "clone pattern: no errors (\(errors))")
    }
}
