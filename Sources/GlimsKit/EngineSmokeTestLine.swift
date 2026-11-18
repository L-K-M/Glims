import AppKit

@MainActor
extension EngineSmokeTest {
    /// The Line tool through the actual canvas: a drag draws one straight
    /// line in the foreground color as one undo step named Line, Shift
    /// keeps it at a multiple of 45 degrees, a click without a drag draws
    /// nothing, an end arrowhead widens toward its base, and while
    /// recording the line adds an explicit unsupported Recorder row.
    static func exerciseLine(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        let image = try session.newImage(width: 160, height: 120)
        let document = try ImageDocument(session: session, image: image, name: "Line")
        guard session.supportsDrawLine else {
            check(!document.toolIsAvailable(.line), "an adapter without slot 244 keeps the Line tool disabled")
            var closed = false; document.closeImageWhenDrained { closed = true }; wait { closed }
            return
        }
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        let state = ToolState.shared
        let oldTool = state.current, oldSettings = state.lineSettings, oldForeground = state.foreground
        defer {
            state.select(oldTool); state.lineSettings = oldSettings; state.foreground = oldForeground
            controller.window?.orderOut(nil)
            var stopped = false; controller.canvas.stopRendering { stopped = true }; wait { stopped }
            var closed = false; document.closeImageWhenDrained { closed = true }; wait { closed }
            documents.items.removeAll { $0 === document }
        }
        guard let window = controller.window else { return check(false, "Line window exists") }
        window.contentView?.layoutSubtreeIfNeeded()
        let canvas = controller.canvas

        func settle() {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 }; spin(0.03)
        }
        func event(_ type: NSEvent.EventType, _ p: CGPoint, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
            let location = canvas.convert(CGPoint(x: p.x * canvas.scale, y: p.y * canvas.scale), to: nil)
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                      clickCount: 1, pressure: 1)
        }
        func drag(_ from: CGPoint, _ to: CGPoint, _ flags: NSEvent.ModifierFlags = []) {
            guard let down = event(.leftMouseDown, from, flags),
                  let moved = event(.leftMouseDragged, CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2), flags),
                  let last = event(.leftMouseDragged, to, flags), let up = event(.leftMouseUp, to, flags) else {
                return check(false, "Line drag events construct")
            }
            canvas.mouseDown(with: down); canvas.mouseDragged(with: moved)
            canvas.mouseDragged(with: last); canvas.mouseUp(with: up)
            settle()
        }
        func red(_ x: Int, _ y: Int) -> Int { Int(pixel(session, image, x: x, y: y)?.first ?? 128) }
        func undoCount() throws -> Int { try session.undoInfo(image).undoCount }

        state.select(.line)
        check(document.toolIsAvailable(.line) && state.current == .line, "the Line tool is available and selected")
        state.foreground = .black
        state.lineSettings = EngineSession.LineDrawSettings(width: 4, antialias: false)

        var before = try undoCount()
        drag(CGPoint(x: 20, y: 60), CGPoint(x: 140, y: 60))
        check(try undoCount() == before + 1 && session.undoInfo(image).nextUndo == "Line",
              "a Line drag is one undo step named Line")
        check(red(80, 58) < 64 && red(80, 61) < 64 && red(80, 57) > 200 && red(80, 62) > 200 &&
              red(20, 60) < 64 && red(19, 60) > 200 && red(140, 60) > 200,
              "the line is 4 px wide in the foreground color and ends square at the drag's ends "
              + "(\(red(80, 57)) \(red(80, 62)) \(red(19, 60)) \(red(140, 60)))")

        before = try undoCount()
        drag(CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 24), .shift)
        check(try undoCount() == before + 1 && red(90, 19) < 64 && red(90, 24) > 200,
              "Shift keeps the line horizontal (\(red(90, 19)) \(red(90, 24)))")

        before = try undoCount()
        drag(CGPoint(x: 30, y: 40), CGPoint(x: 30.2, y: 40.2))
        check(try undoCount() == before, "a click without a drag draws nothing")

        state.lineSettings = EngineSession.LineDrawSettings(width: 2, antialias: false, arrowheads: .end)
        drag(CGPoint(x: 20, y: 100), CGPoint(x: 140, y: 100))
        check(red(122, 96) < 64 && red(122, 103) < 64 && red(60, 96) > 200 && red(138, 96) > 200,
              "an end arrowhead widens toward its base and narrows to its tip "
              + "(\(red(122, 96)) \(red(60, 96)) \(red(138, 96)))")

        try document.startRecording()
        state.lineSettings = EngineSession.LineDrawSettings(width: 4, antialias: false)
        drag(CGPoint(x: 20, y: 80), CGPoint(x: 140, y: 80))
        try document.stopRecording(); settle()
        let rows = document.recorder.records
        if rows.count == 1, case .failure(let reason)? = rows.last?.resolution {
            check(reason == ImageDocument.lineRecordingGap && red(80, 80) < 64,
                  "a line drawn while recording is drawn and records an explicit unsupported row")
        } else { check(false, "a line must not be silently missing from a recording (\(rows.count) rows)") }
    }
}
