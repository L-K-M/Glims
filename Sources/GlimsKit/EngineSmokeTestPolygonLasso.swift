import AppKit

@MainActor
extension EngineSmokeTest {
    /// The Polygon Lasso through the actual canvas: clicks place corners,
    /// a double-click, a click on the first corner or Return closes the
    /// polygon as one selection command, Delete removes the last corner,
    /// Escape, a tool change or too few corners commit nothing, the first
    /// click's modifiers choose the operation, and Shift keeps later edges
    /// at multiples of 45 degrees.
    static func exercisePolygonLasso(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        let image = try session.newImage(width: 160, height: 120)
        let document = try ImageDocument(session: session, image: image, name: "Polygon Lasso")
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
        guard let window = controller.window else { return check(false, "Polygon Lasso window exists") }
        window.contentView?.layoutSubtreeIfNeeded()
        state.selectOptions.antialias = false
        state.selectOptions.operation = .replace
        state.selectOptions.feather = 0
        let canvas = controller.canvas, tools = canvas.tools

        func settle() {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 }; spin(0.03)
        }
        func click(_ p: CGPoint, _ flags: NSEvent.ModifierFlags = [], count: Int = 1) {
            let location = canvas.convert(CGPoint(x: p.x * canvas.scale, y: p.y * canvas.scale), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: count, pressure: 1) else { return check(false, "Polygon Lasso click constructs") }
                if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
            }
        }
        func key(_ code: UInt16, _ characters: String) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
                return check(false, "Polygon Lasso key \(code) constructs")
            }
            canvas.keyDown(with: event)
        }
        func bounds() throws -> CGRect? { try session.selectionBounds(image: image) }
        func undoCount() throws -> Int { try session.undoInfo(image).undoCount }

        state.select(.polygonLasso)
        check(document.toolIsAvailable(.polygonLasso) && ToolID.polygonLasso.isSelectionTool,
              "Polygon Lasso is an available selection tool")

        // Rectangular polygons, so the unantialiased bounds are exact; a
        // sharp vertex rasterizes without the pixel it touches. Four
        // clicks and a double-click on the last corner.
        document.select(.none); settle()
        var before = try undoCount()
        click(CGPoint(x: 20, y: 20)); click(CGPoint(x: 60, y: 20)); click(CGPoint(x: 60, y: 50)); click(CGPoint(x: 20, y: 50))
        check(try bounds() == nil && tools.openPolygonCorners?.count == 4 && document.pendingWork == 0,
              "Polygon Lasso clicks place corners without a native call")
        click(CGPoint(x: 20, y: 50), count: 2); settle()
        check(try bounds() == CGRect(x: 20, y: 20, width: 40, height: 30) && tools.openPolygonCorners == nil,
              "Polygon Lasso double-click closes the polygon")
        check(try undoCount() == before + 1, "Polygon Lasso makes one Undo step")
        try session.undo(image); try document.reload()
        check(try bounds() == nil, "Polygon Lasso Undo restores the empty selection")
        try session.redo(image); try document.reload()
        check(try bounds() == CGRect(x: 20, y: 20, width: 40, height: 30), "Polygon Lasso Redo restores the polygon")

        // A click on the first corner closes and replaces.
        click(CGPoint(x: 10, y: 10)); click(CGPoint(x: 50, y: 10)); click(CGPoint(x: 50, y: 40)); click(CGPoint(x: 10, y: 40))
        click(CGPoint(x: 10.5, y: 10.5)); click(CGPoint(x: 10.5, y: 10.5), count: 2); settle()
        check(try bounds() == CGRect(x: 10, y: 10, width: 40, height: 30) && tools.openPolygonCorners == nil,
              "Polygon Lasso double-click on the first corner closes once and replaces the selection")

        // Delete removes the last corner; Return closes.
        click(CGPoint(x: 10, y: 10)); click(CGPoint(x: 70, y: 10)); click(CGPoint(x: 100, y: 100))
        key(51, "\u{7f}")
        check(tools.openPolygonCorners == [CGPoint(x: 10, y: 10), CGPoint(x: 70, y: 10)],
              "Polygon Lasso Delete removes the last corner")
        click(CGPoint(x: 70, y: 40)); click(CGPoint(x: 10, y: 40)); key(36, "\r"); settle()
        check(try bounds() == CGRect(x: 10, y: 10, width: 60, height: 30), "Polygon Lasso Return closes the polygon")

        // Escape, a tool change and too few corners commit nothing.
        let kept = try bounds()
        before = try undoCount()
        click(CGPoint(x: 100, y: 60)); click(CGPoint(x: 140, y: 60)); click(CGPoint(x: 140, y: 100))
        key(53, "\u{1b}"); settle()
        check(try bounds() == kept && undoCount() == before && tools.openPolygonCorners == nil,
              "Polygon Lasso Escape drops the polygon without a native edit")
        click(CGPoint(x: 100, y: 60)); click(CGPoint(x: 140, y: 60))
        state.select(.rectangleSelect)
        check(tools.openPolygonCorners == nil, "a tool change drops the open polygon")
        state.select(.polygonLasso)
        click(CGPoint(x: 100, y: 60)); click(CGPoint(x: 140, y: 60)); key(36, "\r"); settle()
        check(try bounds() == kept && undoCount() == before && tools.openPolygonCorners == nil,
              "a two-corner polygon commits nothing")

        // The first click's Shift adds; a later Shift keeps 45-degree edges.
        click(CGPoint(x: 100, y: 60), .shift)
        click(CGPoint(x: 140, y: 63), .shift)
        click(CGPoint(x: 141, y: 100), .shift)
        check(tools.openPolygonCorners == [CGPoint(x: 100, y: 60), CGPoint(x: 140, y: 60), CGPoint(x: 140, y: 100)],
              "Polygon Lasso Shift keeps later edges horizontal and vertical")
        click(CGPoint(x: 100, y: 100)); key(36, "\r"); settle()
        check(try bounds() == CGRect(x: 10, y: 10, width: 130, height: 90),
              "Polygon Lasso first-click Shift adds to the selection")
    }
}
