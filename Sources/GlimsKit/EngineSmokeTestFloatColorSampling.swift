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

        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() as Data? else {
            return check(false, "float picker: the wide-gamut fixture profile is available")
        }
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("picker-p3-\(UUID().uuidString).icc")
        try p3.write(to: profile)
        defer { try? FileManager.default.removeItem(at: profile) }
        // Assign after filling so the stored red becomes an actual P3 red;
        // filling after assignment would convert sRGB red into the working space.
        try session.fill(image: image, at: .zero, mode: .selection,
                         color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        try session.assignProfile(image, path: profile.path)
        let wide = try session.sampleColor(image, x: 2, y: 3)
        check(wide.red > 1 && (wide.green < 0 || wide.blue < 0),
              "float picker: the native wide-gamut sample really exceeds bounded sRGB")
        let wideInfo = try session.info(image), wideHistory = try session.undoInfo(image)
        let wideColor = try session.colorInfo(image)
        let priorStatus = owner.canvas.tools.onStatus
        var messages: [String] = []
        owner.canvas.tools.onStatus = { message in messages.append(message); priorStatus?(message) }
        pick(CGPoint(x: 2.5, y: 3.5), tool: .eyedropper)
        owner.canvas.tools.onStatus = priorStatus
        let selected = state.foreground.usingColorSpace(.sRGB)
        check(selected?.redComponent == 1 && selected?.greenComponent == 0 && selected?.blueComponent == 0,
              "float picker: an extended sample is bounded only when becoming an editing color")
        check(messages.contains { $0.contains("clipped to 0–1") },
              "float picker: editing-color clipping is explicitly reported")
        check((try? session.info(image)) == wideInfo && (try? session.undoInfo(image)) == wideHistory
            && (try? session.colorInfo(image)) == wideColor,
              "float picker: clipping the tool color leaves the wide-gamut image and Undo unchanged")
    }
}
