import AppKit

@MainActor
extension EngineSmokeTest {
    /// Real canvas input on an opaque Background, with a color change during the gesture.
    static func exerciseEraserBackground(_ session: EngineSession, documents: DocumentList) throws {
        func expect(_ value: Bool, _ text: String) { check(value, "Eraser background: \(text)") }
        func require(_ value: Bool, _ text: String) throws {
            guard value else { throw NSError(domain: "EraserBackgroundSmoke", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: text]) }
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents() }
            return condition()
        }
        let state = ToolState.shared
        let previousTool = state.current, previousForeground = state.foreground, previousBackground = state.background
        let previousEraser = state.brush(for: .eraser)
        defer {
            state.update(.eraser) { $0 = previousEraser }
            state.foreground = previousForeground; state.background = previousBackground; state.select(previousTool)
        }
        let reference = try session.newImage(width: 40, height: 24)
        defer { try? session.closeImage(reference) }
        let image = try session.newImage(width: 40, height: 24)
        let fill = NSColor(srgbRed: 0.65, green: 0.4, blue: 0.4, alpha: 1)
        let referenceLayer: Int32, before: Data, document: ImageDocument
        do {
            try session.fill(image: image, at: .zero, mode: .selection, color: fill)
            try session.fill(image: reference, at: .zero, mode: .selection, color: fill)
            referenceLayer = try session.layers(reference)[0].id
            before = try session.copyPixels(image, merged: true).pixels
            document = try ImageDocument(session: session, image: image, name: "Eraser background")
        } catch {
            try? session.closeImage(image)
            throw error
        }
        documents.items.append(document)
        let owner = DocumentWindowController(document: document)
        owner.showWindow(nil); owner.window?.makeKeyAndOrderFront(nil); owner.zoom(to: 600)
        var errors: [String] = []
        document.onError = { errors.append($0) }
        defer {
            owner.window?.orderOut(nil)
            var stopped = false; owner.canvas.stopRendering { stopped = true }
            expect(wait { stopped }, "canvas renderer stops")
            owner.window?.close()
            var closed = false; document.closeImageWhenDrained { closed = true }
            expect(wait { closed && (try? session.info(image)) == nil }, "owned image closes")
            documents.items.removeAll { $0 === document }
        }
        func drain() throws {
            try require(wait { document.pendingWork == 0 && !document.strokeIsActive && !EngineActivity.shared.isBusy },
                        "the stroke did not settle")
        }
        try drain()
        NSApp.activate(ignoringOtherApps: true); owner.window?.makeMain(); owner.window?.makeKeyAndOrderFront(nil)
        try require(wait { NSApp.isActive && NSApp.mainWindow === owner.window }, "document window is not main")
        state.foreground = .red
        state.background = NSColor(srgbRed: 0.1, green: 0.4, blue: 0.7, alpha: 1)
        state.update(.eraser) { $0.size = 10; $0.opacity = 1; $0.hardness = 1; $0.pressureSize = false; $0.resource = nil }
        state.select(.eraser)
        let brush = state.brush(for: .eraser)
        let points: [EngineSession.StrokePoint] = [
            .init(x: 8, y: 9, pressure: 1, timeMilliseconds: 1000),
            .init(x: 11, y: 10, pressure: 1, timeMilliseconds: 1100),
            .init(x: 13, y: 11, pressure: 1, timeMilliseconds: 1200)
        ]
        func pointer(_ type: NSEvent.EventType, _ point: EngineSession.StrokePoint) throws {
            guard let window = owner.window,
                  let event = NSEvent.mouseEvent(with: type,
                    location: owner.canvas.convert(CGPoint(x: point.x * owner.canvas.scale, y: point.y * owner.canvas.scale), to: nil),
                    modifierFlags: [], timestamp: Double(point.timeMilliseconds) / 1000, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1), event.subtype != .tabletPoint else {
                throw NSError(domain: "EraserBackgroundSmoke", code: 2)
            }
            switch type {
            case .leftMouseDown: owner.canvas.mouseDown(with: event)
            case .leftMouseDragged: owner.canvas.mouseDragged(with: event)
            default: owner.canvas.mouseUp(with: event)
            }
        }
        try pointer(.leftMouseDown, points[0])
        state.background = .green
        try pointer(.leftMouseDragged, points[1]); try pointer(.leftMouseUp, points[2]); try drain()
        let after = try session.copyPixels(image, merged: true).pixels
        let supported = ProcessInfo.processInfo.environment["GLIMS_EXPECT_ERASER_BACKGROUND"] == "1"
        if supported {
            let stroke = try session.beginStroke(image: reference, drawable: referenceLayer, brush: brush, first: points[0])
            try session.continueStroke(stroke, points: [points[1]])
            try session.continueStroke(stroke, points: [points[2]])
            try session.endStroke(stroke)
            let expected = try session.copyPixels(reference, merged: true).pixels
            expect(errors.isEmpty && after != before && after == expected,
                   "canvas uses the background captured at mouse-down despite later color changes")
            document.undo(); try drain()
            expect(try session.copyPixels(image, merged: true).pixels == before, "one Undo restores the opaque layer")
        } else {
            expect(after == before && errors.contains(where: { $0.contains("selected eraser background color") }),
                   "older engine refuses the unsupported color without changing pixels")
        }
    }
}
