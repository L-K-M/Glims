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
        func flagsChanged(_ flags: NSEvent.ModifierFlags, at p: CGPoint) -> NSEvent? {
            let canvas = controller.canvas
            let location = canvas.convert(CGPoint(x: p.x * canvas.scale, y: p.y * canvas.scale), to: nil)
            return NSEvent.keyEvent(with: .flagsChanged, location: location, modifierFlags: flags,
                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                    characters: "", charactersIgnoringModifiers: "",
                                    isARepeat: false, keyCode: 56)
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

        // MARK: Transform modifier routing

        // The Transform tool's preview is local until Return; Shift must
        // recompute it from the captured drag and the pointer's current
        // location without a pointer move, and release must restore the
        // free geometry. The release on mouseUp must use the final
        // coordinates and modifiers.
        state.select(.transform)
        let transformLayer = document.activeLayer
        let transformBounds = document.layers.first(where: { $0.id == transformLayer })?.bounds
        guard let transformLayer, let transformBounds,
              transformBounds == CGRect(x: 0, y: 0, width: 160, height: 120) else {
            return check(false, "the transform fixture's active layer covers the image")
        }
        let undoBeforeTransform = document.undoInfo.undoCount
        func transformUndoIntact() -> Bool {
            document.undoInfo.undoCount == undoBeforeTransform
                && document.layers.first(where: { $0.id == transformLayer })?.bounds == transformBounds
        }

        // Picking a handle within its hit tolerance must not create a
        // transform before the pointer has moved.
        let nearCorner = CGPoint(x: 158, y: 119)
        controller.canvas.mouseDown(with: mouse(.leftMouseDown, nearCorner, []))
        if let stationaryShift = flagsChanged([.shift], at: nearCorner) {
            controller.canvas.flagsChanged(with: stationaryShift)
        }
        check(controller.canvas.tools.transformSession?.isIdentity == true,
              "stationary Shift on a near-handle press preserves the captured geometry")
        controller.canvas.mouseUp(with: mouse(.leftMouseUp, nearCorner, []))
        check(controller.canvas.tools.transformSession?.isIdentity == true && transformUndoIntact(),
              "clicking near a transform handle without moving creates no preview change or Undo")
        if let cancelClick = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                              timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                              characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                              isARepeat: false, keyCode: 53) {
            controller.canvas.keyDown(with: cancelClick)
        }

        // A corner drag previews free, Shift constrains it in place, and
        // releasing Shift restores the free box without moving the pointer.
        let corner = CGPoint(x: transformBounds.maxX, y: transformBounds.maxY)
        let freeTarget = CGPoint(x: 200, y: 130)
        controller.canvas.mouseDown(with: mouse(.leftMouseDown, corner, []))
        controller.canvas.mouseDragged(with: mouse(.leftMouseDragged, freeTarget, []))
        check(controller.canvas.tools.transformSession?.box == CGRect(x: 0, y: 0, width: 200, height: 130),
              "a free corner drag previews the unconstrained box")
        if let shiftDown = flagsChanged([.shift], at: freeTarget) {
            controller.canvas.flagsChanged(with: shiftDown)
        } else { check(false, "the Shift press event constructs") }
        check(controller.canvas.tools.transformSession?.box == CGRect(x: 0, y: 0, width: 200, height: 150),
              "pressing Shift without moving the pointer constrains the corner preview")
        if let shiftUp = flagsChanged([], at: freeTarget) {
            controller.canvas.flagsChanged(with: shiftUp)
        } else { check(false, "the Shift release event constructs") }
        check(controller.canvas.tools.transformSession?.box == CGRect(x: 0, y: 0, width: 200, height: 130),
              "releasing Shift without moving the pointer restores the free corner preview")
        // A Shift drag, then a release on the mouseUp's final coordinates.
        controller.canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 190, y: 125), .shift))
        check(controller.canvas.tools.transformSession?.box == CGRect(x: 0, y: 0, width: 190, height: 142.5),
              "a Shift corner drag previews the constrained box")
        controller.canvas.mouseUp(with: mouse(.leftMouseUp, freeTarget, []))
        check(controller.canvas.tools.transformSession?.box == CGRect(x: 0, y: 0, width: 200, height: 130),
              "mouseUp processes its final coordinates and modifiers before ending the drag")
        check(controller.canvas.tools.transformSession != nil && transformUndoIntact(),
              "the corner preview leaves the layer and Undo history untouched")
        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                         characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                         isARepeat: false, keyCode: 53) {
            controller.canvas.keyDown(with: escape)
        } else { check(false, "the transform cancel event constructs") }
        check(controller.canvas.tools.transformSession == nil && transformUndoIntact(),
              "Escape cancels the pending corner transform with no mutation")

        // A rotation drag: Shift snaps to 15 degrees and release restores
        // the free angle, again without moving the pointer.
        let rotateStart = CGPoint(x: 200, y: 100)
        let rotateFree = CGPoint(x: 200, y: 150)
        let freeAngle = atan2(Double(90), Double(120)) - atan2(Double(40), Double(120))
        controller.canvas.mouseDown(with: mouse(.leftMouseDown, rotateStart, []))
        controller.canvas.mouseDragged(with: mouse(.leftMouseDragged, rotateFree, []))
        check(abs((controller.canvas.tools.transformSession?.angle ?? -1) - freeAngle) < 1e-9,
              "a free rotation drag previews the free angle")
        if let rotateShiftDown = flagsChanged([.shift], at: rotateFree) {
            controller.canvas.flagsChanged(with: rotateShiftDown)
        } else { check(false, "the rotation Shift press event constructs") }
        check(abs((controller.canvas.tools.transformSession?.angle ?? -1) - .pi / 12) < 1e-9,
              "pressing Shift without moving the pointer snaps the rotation to 15 degrees")
        if let rotateShiftUp = flagsChanged([], at: rotateFree) {
            controller.canvas.flagsChanged(with: rotateShiftUp)
        } else { check(false, "the rotation Shift release event constructs") }
        check(abs((controller.canvas.tools.transformSession?.angle ?? -1) - freeAngle) < 1e-9,
              "releasing Shift without moving the pointer restores the free rotation")
        controller.canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 200, y: 140), .shift))
        controller.canvas.mouseUp(with: mouse(.leftMouseUp, rotateFree, []))
        check(abs((controller.canvas.tools.transformSession?.angle ?? -1) - freeAngle) < 1e-9,
              "mouseUp restores the free rotation after a Shift drag ends")
        check(controller.canvas.tools.transformSession != nil && transformUndoIntact(),
              "the rotation preview leaves the layer and Undo history untouched")
        if let rotateEscape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                               characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                               isARepeat: false, keyCode: 53) {
            controller.canvas.keyDown(with: rotateEscape)
        } else { check(false, "the rotation cancel event constructs") }
        check(controller.canvas.tools.transformSession == nil && transformUndoIntact(),
              "Escape cancels the pending rotation with no mutation")
    }
}
