import AppKit

@MainActor
extension EngineSmokeTest {
    /// The picker must retain fractions that a display-byte roundtrip loses.
    static func exerciseFloatColorSampling(_ session: EngineSession, documents: DocumentList) throws {
        let state = ToolState.shared
        let oldTool = state.current, oldForeground = state.foreground, oldBackground = state.background
        var controller: DocumentWindowController?
        var orphan: Int32?
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while !condition(), Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return condition()
        }
        defer {
            state.foreground = oldForeground; state.background = oldBackground
            state.select(oldTool); state.notifyChange()
            if let controller {
                controller.closeDiscardingChanges()
                check(wait { controller.imageDocument.pendingWork == 0
                    && (try? session.info(controller.imageDocument.image)) == nil },
                    "float picker: the owned document drains and closes")
                documents.items.removeAll { $0 === controller.imageDocument }
            }
            if let orphan { try? session.closeImage(orphan) }
        }
        let image = try session.newImage(width: 8, height: 8)
        orphan = image
        try session.convertPrecision(image, component: .float, trc: .nonlinear)
        let expected = [0.1234567, 0.4567891, 0.7891234]
        try session.fill(image: image, at: .zero, mode: .selection,
            color: NSColor(srgbRed: expected[0], green: expected[1], blue: expected[2], alpha: 1))
        let document = try ImageDocument(session: session, image: image, name: "Float color picker")
        let owner = DocumentWindowController(document: document)
        controller = owner; orphan = nil; documents.items.append(document)
        owner.showWindow(nil)
        owner.zoom(to: 100)
        guard let window = owner.window else { return check(false, "float picker: an actual canvas window exists") }
        let before = try session.info(image), history = try session.undoInfo(image)
        let pixels = try session.copyPixels(image, merged: true).pixels
        check(try session.colorInfo(image).component == .float,
              "float picker: the source really uses 32-bit float components")
        func pick(_ point: CGPoint, tool: ToolID, flags: NSEvent.ModifierFlags = []) {
            state.foreground = .white; state.background = .black; state.select(tool); state.notifyChange()
            let location = owner.canvas.convert(CGPoint(x: point.x * owner.canvas.scale,
                                                        y: point.y * owner.canvas.scale), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: location,
                    modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                if type == .leftMouseDown { owner.canvas.mouseDown(with: event) }
                else { owner.canvas.mouseUp(with: event) }
            }
        }
        let routes: [(ToolID, NSEvent.ModifierFlags, String)] = [
            (.eyedropper, [], "Color Picker"), (.paintbrush, .option, "Option-paint picker")]
        for (tool, flags, name) in routes {
            pick(CGPoint(x: 2.5, y: 3.5), tool: tool, flags: flags)
            let actual = state.foreground.usingColorSpace(.sRGB)
            let values = actual.map { [Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent)] }
            check(values.map { zip($0, expected).allSatisfy { abs($0.0 - $0.1) < 0.00001 } } == true,
                  "float picker: \(name) retains all source fractions beyond display-byte precision (\(String(describing: values)))")
            check(state.background == .black && state.foreground.alphaComponent == 1,
                  "float picker: \(name) changes only the opaque foreground")
        }
        pick(CGPoint(x: -1, y: 2), tool: .eyedropper)
        check(state.foreground == .white, "float picker: an outside-canvas click preserves the foreground")
        check((try? session.info(image)) == before && (try? session.undoInfo(image)) == history
                && (try? session.copyPixels(image, merged: true).pixels) == pixels,
              "float picker: sampling leaves image state, pixels and Undo unchanged")
    }
}
