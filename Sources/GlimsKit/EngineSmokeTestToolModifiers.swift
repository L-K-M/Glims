import AppKit

/// Modifier keys through real canvas events: Shift holds a gradient to 45
/// degrees, and Option makes the Eyedropper set the background color.
extension EngineSmokeTest {
    static func exerciseToolModifiers(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        let image = try session.newImage(width: 160, height: 120)
        let document = try ImageDocument(session: session, image: image, name: "Tool Modifiers")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        let state = ToolState.shared
        let oldTool = state.current, oldLine = state.lineSettings, oldForeground = state.foreground
        let oldBackground = state.background
        defer {
            state.select(oldTool); state.lineSettings = oldLine; state.foreground = oldForeground
            state.background = oldBackground
            controller.window?.orderOut(nil)
            var stopped = false; controller.canvas.stopRendering { stopped = true }; wait { stopped }
            var closed = false; document.closeImageWhenDrained { closed = true }; wait { closed }
            documents.items.removeAll { $0 === document }
        }
        guard let window = controller.window else { return check(false, "Tool modifier window exists") }
        window.contentView?.layoutSubtreeIfNeeded()
        let canvas = controller.canvas

        func settle() {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 }; spin(0.03)
        }
        func gesture(_ points: [CGPoint], _ flags: NSEvent.ModifierFlags = [],
                     press: NSEvent.ModifierFlags? = nil) {
            guard let first = points.first, let last = points.last else { return }
            let steps = [(NSEvent.EventType.leftMouseDown, first)]
                + points.dropFirst().map { (NSEvent.EventType.leftMouseDragged, $0) }
                + [(NSEvent.EventType.leftMouseUp, last)]
            for (type, point) in steps {
                let location = canvas.convert(CGPoint(x: point.x * canvas.scale, y: point.y * canvas.scale), to: nil)
                guard let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: type == .leftMouseDown ? press ?? flags : flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                    return check(false, "tool modifier events construct")
                }
                switch type {
                case .leftMouseDown: canvas.mouseDown(with: event)
                case .leftMouseDragged: canvas.mouseDragged(with: event)
                default: canvas.mouseUp(with: event)
                }
            }
            settle()
        }
        func red(_ x: Int, _ y: Int) -> Int { Int(pixel(session, image, x: x, y: y)?.first ?? 128) }

        func brightness(_ color: NSColor) -> Double {
            Double(color.usingColorSpace(.sRGB)?.redComponent ?? -1)
        }

        state.select(.line)
        state.foreground = .black
        state.lineSettings = EngineSession.LineDrawSettings(width: 20, antialias: false)
        gesture([CGPoint(x: 30, y: 4), CGPoint(x: 30, y: 60), CGPoint(x: 30, y: 116)])
        check(red(30, 60) < 64 && red(120, 60) > 200, "the tool modifier fixture has black and white")

        state.select(.eyedropper)
        state.foreground = .red
        state.background = .green
        gesture([CGPoint(x: 30.5, y: 60.5)], .option)
        check(brightness(state.background) < 0.25 && state.foreground == .red,
              "Option-click with the Eyedropper sets only the background color")
        gesture([CGPoint(x: 30.5, y: 60.5), CGPoint(x: 120.5, y: 60.5)], press: .option)
        check(brightness(state.background) > 0.75 && state.foreground == .red,
              "an Eyedropper drag keeps the color that its press chose")
        state.background = .green
        gesture([CGPoint(x: 30.5, y: 60.5)])
        check(brightness(state.foreground) < 0.25 && state.background == .green,
              "a plain Eyedropper click still sets only the foreground color")

        state.foreground = .black
        state.background = .white
        state.select(.gradient)
        gesture([CGPoint(x: 20, y: 40), CGPoint(x: 80, y: 55), CGPoint(x: 140, y: 70)], .shift)
        let top = red(80, 4), bottom = red(80, 115)
        check(abs(red(24, 60) - red(136, 60)) > 40 && abs(top - bottom) <= 6,
              "Shift holds a Gradient drag to 45 degrees (\(top) \(bottom))")
        gesture([CGPoint(x: 20, y: 40), CGPoint(x: 80, y: 55), CGPoint(x: 140, y: 70)])
        check(abs(red(80, 4) - red(80, 115)) > 20, "a plain Gradient drag follows the pointer")
    }
}
