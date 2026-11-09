import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseSelectionDrag(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        let image = try session.newImage(width: 160, height: 120)
        let document = try ImageDocument(session: session, image: image, name: "Selection modifiers")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        let state = ToolState.shared, oldTool = state.current, oldOptions = state.selectOptions
        defer {
            state.select(oldTool); state.selectOptions = oldOptions
            controller.window?.orderOut(nil)
            var stopped = false; controller.canvas.stopRendering { stopped = true }; wait { stopped }
            var closed = false; document.closeImageWhenDrained { closed = true }; wait { closed }
            documents.items.removeAll { $0 === document }
        }
        guard let window = controller.window else { return check(false, "selection window exists") }
        window.contentView?.layoutSubtreeIfNeeded()
        state.selectOptions.antialias = false
        state.selectOptions.operation = .replace
        state.selectOptions.feather = 0
        state.selectOptions.cornerRadius = 0
        func settle() {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 }; spin(0.03)
        }
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            let canvas = controller.canvas
            let point = canvas.convert(CGPoint(x: p.x * canvas.scale, y: p.y * canvas.scale), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                      clickCount: 1, pressure: 1)!
        }
        @discardableResult func drag(_ tool: ToolID, start: CGPoint, end: CGPoint,
                  down: NSEvent.ModifierFlags = [], during: NSEvent.ModifierFlags = [],
                  up: NSEvent.ModifierFlags? = nil) -> CGRect? {
            state.select(tool)
            controller.canvas.mouseDown(with: mouse(.leftMouseDown, start, down))
            controller.canvas.mouseDragged(with: mouse(.leftMouseDragged, end, during))
            let preview = controller.canvas.tools.selectionDragRect
            controller.canvas.mouseUp(with: mouse(.leftMouseUp, end, up ?? during))
            settle()
            return preview
        }
        let start = CGPoint(x: 60, y: 50), end = CGPoint(x: 80, y: 60)
        for tool in [ToolID.rectangleSelect, .ellipseSelect] {
            document.select(.none); settle()
            let before = try session.undoInfo(image).undoCount
            let preview = drag(tool, start: start, end: end, during: .shift)
            check(try session.selectionBounds(image: image) == CGRect(x: 60, y: 50, width: 20, height: 20),
                  "\(tool.name) constrains a live Shift drag to equal sides")
            check(preview == CGRect(x: 60, y: 50, width: 20, height: 20),
                  "\(tool.name) rubber band uses the same constrained bounds")
            check(try session.undoInfo(image).undoCount == before + 1,
                  "\(tool.name) modifier selection makes one Undo step")
            try session.undo(image); try document.reload()
            check(try session.selectionBounds(image: image) == nil, "\(tool.name) Undo restores the empty selection")
            try session.redo(image); try document.reload()
            check(try session.selectionBounds(image: image) == CGRect(x: 60, y: 50, width: 20, height: 20),
                  "\(tool.name) Redo restores the constrained selection")
            drag(tool, start: start, end: end, during: .option)
            check(try session.selectionBounds(image: image) == CGRect(x: 40, y: 40, width: 40, height: 20),
                  "\(tool.name) live Option draws about the press point")
            drag(tool, start: start, end: CGPoint(x: 40, y: 40), during: [.option, .shift])
            check(try session.selectionBounds(image: image) == CGRect(x: 40, y: 30, width: 40, height: 40),
                  "\(tool.name) combines center and equal sides in a reverse drag")
            drag(tool, start: start, end: end, during: [.option, .shift], up: [])
            check(try session.selectionBounds(image: image) == CGRect(x: 60, y: 50, width: 20, height: 10),
                  "\(tool.name) release flags determine the committed geometry")
        }
        state.select(.rectangleSelect)
        try session.select(.rectangle(CGRect(x: 10, y: 10, width: 10, height: 10)), image: image)
        try document.reload()
        drag(.rectangleSelect, start: start, end: end, down: .shift, during: [])
        check(try session.selectionBounds(image: image) == CGRect(x: 10, y: 10, width: 70, height: 50),
              "the press captures Add while later flags change only geometry")
        try session.select(.rectangle(CGRect(x: 10, y: 10, width: 100, height: 100)), image: image)
        try document.reload()
        drag(.rectangleSelect, start: CGPoint(x: 60, y: 10), end: CGPoint(x: 110, y: 110), down: .option)
        check(try session.selectionBounds(image: image) == CGRect(x: 10, y: 10, width: 50, height: 100),
              "the press captures Subtract after Option is released")
        try session.select(.rectangle(CGRect(x: 10, y: 10, width: 60, height: 60)), image: image)
        try document.reload()
        drag(.rectangleSelect, start: CGPoint(x: 40, y: 40), end: CGPoint(x: 90, y: 90), down: [.option, .shift])
        check(try session.selectionBounds(image: image) == CGRect(x: 40, y: 40, width: 30, height: 30),
              "the press captures Intersect after both modifiers are released")
        controller.canvas.mouseDown(with: mouse(.leftMouseDown, start, []))
        controller.canvas.mouseDragged(with: mouse(.leftMouseDragged, end, []))
        if let flags = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.shift, .option],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56) {
            controller.canvas.flagsChanged(with: flags)
            check(controller.canvas.tools.selectionDragRect == CGRect(x: 40, y: 30, width: 40, height: 40),
                  "modifier-only events update a stationary rubber band")
        } else { check(false, "stationary modifier event constructs") }
        let beforeCancel = try session.selectionBounds(image: image), undoBeforeCancel = try session.undoInfo(image).undoCount
        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option, .shift],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            controller.canvas.keyDown(with: escape)
            controller.canvas.mouseUp(with: mouse(.leftMouseUp, end, [.option, .shift])); settle()
            check(try session.selectionBounds(image: image) == beforeCancel && session.undoInfo(image).undoCount == undoBeforeCancel
                  && controller.canvas.tools.selectionDragRect == nil,
                  "Escape with held modifiers cancels without changing selection or history")
        } else { check(false, "selection cancel event constructs") }
    }
}
