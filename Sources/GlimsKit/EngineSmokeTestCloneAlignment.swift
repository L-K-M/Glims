import AppKit

/// Clone's alignment through real canvas clicks: the strokes after the first
/// keep the distance to the source instead of restarting at the source point.
extension EngineSmokeTest {
    static func exerciseCloneAlignment(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        let image = try session.newImage(width: 160, height: 120)
        let document = try ImageDocument(session: session, image: image, name: "Clone Alignment")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        let state = ToolState.shared
        let oldTool = state.current, oldLine = state.lineSettings, oldForeground = state.foreground
        let oldSource = state.cloneSource, oldBrush = state.brush(for: .clone)
        defer {
            state.update(.clone) { $0 = oldBrush }
            state.select(oldTool); state.lineSettings = oldLine; state.foreground = oldForeground
            state.cloneSource = oldSource
            controller.window?.orderOut(nil)
            var stopped = false; controller.canvas.stopRendering { stopped = true }; wait { stopped }
            var closed = false; document.closeImageWhenDrained { closed = true }; wait { closed }
            documents.items.removeAll { $0 === document }
        }
        guard let window = controller.window else { return check(false, "Clone alignment window exists") }
        window.contentView?.layoutSubtreeIfNeeded()
        let canvas = controller.canvas

        func settle() {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 }; spin(0.03)
        }
        func gesture(_ points: [CGPoint], _ flags: NSEvent.ModifierFlags = []) {
            guard let first = points.first, let last = points.last else { return }
            let steps = [(NSEvent.EventType.leftMouseDown, first)]
                + points.dropFirst().map { (NSEvent.EventType.leftMouseDragged, $0) }
                + [(NSEvent.EventType.leftMouseUp, last)]
            for (type, point) in steps {
                let location = canvas.convert(CGPoint(x: point.x * canvas.scale, y: point.y * canvas.scale), to: nil)
                guard let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                    return check(false, "Clone alignment events construct")
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

        // A black band around x = 60 on white tells the sampled column apart.
        state.select(.line)
        state.foreground = .black
        state.lineSettings = EngineSession.LineDrawSettings(width: 12, antialias: false)
        gesture([CGPoint(x: 60, y: 4), CGPoint(x: 60, y: 60), CGPoint(x: 60, y: 116)])
        check(red(60, 40) < 64 && red(20, 40) > 200, "the Clone alignment fixture has a band and white")

        state.select(.clone)
        state.update(.clone) { $0.size = 8; $0.hardness = 1; $0.opacity = 1; $0.resource = nil; $0.pressureSize = false }

        gesture([CGPoint(x: 20.5, y: 40.5)], .option)
        gesture([CGPoint(x: 100.5, y: 40.5)])
        check(red(100, 40) > 200, "the first Clone stroke copies from the source point (\(red(100, 40)))")
        let before = try session.undoInfo(image).undoCount
        gesture([CGPoint(x: 140.5, y: 40.5)])
        let after = try session.undoInfo(image).undoCount
        check(red(140, 40) < 64 && after == before + 1,
              "a second aligned Clone stroke keeps its distance to the source (\(red(140, 40)))")

        gesture([CGPoint(x: 60.5, y: 80.5)], .option)
        gesture([CGPoint(x: 120.5, y: 90.5)])
        check(red(120, 90) < 64, "a new source starts a new alignment (\(red(120, 90)))")

        let wasAligned = state.cloneAlignment.isAligned
        defer { state.cloneAlignment.isAligned = wasAligned }
        state.cloneAlignment.isAligned = false
        gesture([CGPoint(x: 100.5, y: 20.5)])
        gesture([CGPoint(x: 140.5, y: 20.5)])
        check(red(100, 20) < 64 && red(140, 20) < 64,
              "with Aligned off every stroke restarts at the source (\(red(100, 20)) \(red(140, 20)))")
    }
}
