import AppKit
import CoreGraphics

@MainActor
extension EngineSmokeTest {
    /// Synthetic AppKit packets and a separately configured native eraser;
    /// this is not evidence from a physical tablet or its driver.
    static func exerciseTabletEraserProximity(_ session: EngineSession, documents: DocumentList) throws {
        var count = 0
        func expect(_ value: Bool, _ message: String) {
            count += 1; check(value, "tablet eraser: \(message)")
        }
        func wait(_ message: String, _ condition: () -> Bool) throws {
            let end = Date().addingTimeInterval(15)
            while Date() < end {
                if condition() { return }
                EngineSmokeTestHost.pumpEvents()
            }
            throw NSError(domain: "TabletEraserFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        func require(_ value: Bool, _ message: String) throws {
            guard value else {
                throw NSError(domain: "TabletEraserFixture", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let state = ToolState.shared
        let oldTool = state.current, oldForeground = state.foreground
        let oldEraser = state.brush(for: .eraser), oldPencil = state.brush(for: .pencil)
        let monitor = TabletEraserProximity.shared
        var owner: DocumentWindowController?
        var document: ImageDocument?
        var nativeImages: [Int32] = []
        var complete = false
        defer {
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            if let owner, let document {
                owner.window?.close()
                try? wait("owned document closes", { (try? session.info(document.image)) == nil })
                expect((try? session.info(document.image)) == nil, "owned image closes before engine shutdown")
                documents.items.removeAll { $0 === document }
            }
            nativeImages.forEach { try? session.closeImage($0) }
            state.foreground = oldForeground
            state.update(.eraser) { $0 = oldEraser }
            state.update(.pencil) { $0 = oldPencil }
            state.select(oldTool)
            expect(complete, "all synthetic proximity and native pixel scenarios complete")
            print("     tablet-eraser checks: \(count)")
        }
        let red = ClipboardImage(width: 96, height: 64,
            pixels: Data((0..<(96 * 64)).flatMap { _ in [UInt8(220), 30, 50, 255] }), origin: .zero)
        func image() throws -> (Int32, Int32) {
            let image = try session.newImage(width: 96, height: 64)
            nativeImages.append(image)
            let layer = try session.pastePixels(image, pixels: red, at: .zero)
            try session.selectLayer(layer, image: image)
            return (image, layer)
        }
        let (actualImage, _) = try image()
        let doc = try ImageDocument(session: session, image: actualImage, name: "Tablet eraser synthetic input")
        document = doc; documents.items.append(doc)
        nativeImages.removeAll { $0 == actualImage }
        let controller = DocumentWindowController(document: doc); owner = controller
        controller.showWindow(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.canvas)
        try wait("the actual canvas becomes key", { NSApp.isActive && NSApp.keyWindow === controller.window })
        let canvas = controller.canvas
        let (referenceImage, referenceLayer) = try image()
        let initialPixels = try session.copyPixels(actualImage, merged: true).pixels
        let initialHistory = try session.undoInfo(actualImage)
        func drain() throws {
            try wait("accepted native input and reads drain", { doc.pendingWork == 0 && !EngineActivity.shared.isBusy })
        }
        func point(_ type: NSEvent.EventType, _ p: CGPoint, _ time: Double,
                   device: UInt?, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            guard let window = controller.window,
                  let template = NSEvent.mouseEvent(with: type,
                    location: canvas.convert(CGPoint(x: p.x * canvas.scale, y: p.y * canvas.scale), to: nil),
                    modifierFlags: flags, timestamp: time, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw NSError(domain: "TabletEraserFixture", code: 3)
            }
            guard let device else { return template }
            guard let packet = template.cgEvent else { throw NSError(domain: "TabletEraserFixture", code: 4) }
            packet.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
            packet.setIntegerValueField(.tabletEventDeviceID, value: Int64(device))
            packet.setDoubleValueField(.tabletEventPointPressure, value: 1)
            packet.setDoubleValueField(.mouseEventPressure, value: 1)
            packet.timestamp = UInt64(time * 1_000_000_000)
            guard let event = NSEvent(cgEvent: packet) else { throw NSError(domain: "TabletEraserFixture", code: 5) }
            // Fixture admission must prove the public packet decoded correctly;
            // no private NSEvent layout or fake point/proximity getters are used.
            try require(event.subtype == .tabletPoint && UInt(exactly: event.deviceID) == device,
                        "CGEvent did not preserve the synthetic tablet device")
            let mapped = canvas.imagePoint(for: event)
            try require(abs(mapped.x - p.x) < 0.001 && abs(mapped.y - p.y) < 0.001
                        && abs(Double(event.pressure) - 1) < 0.001,
                        "CGEvent tablet packet coordinates/pressure do not match the literal fixture")
            return event
        }
        let probe = try point(.leftMouseDown, CGPoint(x: 12, y: 16), 10, device: 42)
        func proximity(_ id: UInt, entering: Bool, eraser: Bool, mirrored: Bool) throws {
            guard let packet = CGEvent(source: nil) else { throw NSError(domain: "TabletEraserFixture", code: 6) }
            packet.type = mirrored ? .mouseMoved : .tabletProximity
            if mirrored {
                packet.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletProximity.rawValue))
            }
            packet.setIntegerValueField(.tabletProximityEventDeviceID, value: Int64(id))
            packet.setIntegerValueField(.tabletProximityEventPointerType,
                value: Int64((eraser ? NSEvent.PointingDeviceType.eraser : .pen).rawValue))
            packet.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
            guard let event = NSEvent(cgEvent: packet) else { throw NSError(domain: "TabletEraserFixture", code: 7) }
            try require(TabletEraserProximity.isProximityEvent(event)
                        && UInt(exactly: event.deviceID) == id && event.isEnteringProximity == entering
                        && (event.pointingDeviceType == .eraser) == eraser,
                        "CGEvent did not preserve the documented proximity representation")
            let selected: ToolID = .pencil
            let expected: ToolID = entering && eraser ? .eraser : selected
            let checkPoint = try point(.leftMouseDown, CGPoint(x: 12, y: 16), 10, device: id)
            NSApp.postEvent(event, atStart: false)
            try wait("passive local monitor sees the actual proximity event", {
                monitor.effectiveTool(selected: selected, event: checkPoint) == expected
            })
            // Leave/pen reports can already match before dispatch. Pump once
            // as well, so subsequent checks cannot overtake their queued event.
            EngineSmokeTestHost.pumpEvents()
        }
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        expect(monitor.effectiveTool(selected: .pencil, event: probe) == .pencil,
               "missing proximity preserves the explicit selected tool")
        state.select(.pencil)
        try proximity(42, entering: true, eraser: true, mirrored: false)
        expect(monitor.effectiveTool(selected: .pencil, event: probe) == .eraser && state.current == .pencil,
               "standalone proximity enables only a temporary matching-device eraser")
        let other = try point(.leftMouseDown, CGPoint(x: 12, y: 16), 10, device: 43)
        let mouse = try point(.leftMouseDown, CGPoint(x: 12, y: 16), 10, device: nil)
        expect(monitor.effectiveTool(selected: .pencil, event: other) == .pencil
               && monitor.effectiveTool(selected: .pencil, event: mouse) == .pencil,
               "nonmatching tablet and ordinary mouse do not borrow Eraser")
        try proximity(42, entering: false, eraser: false, mirrored: false)
        expect(monitor.effectiveTool(selected: .pencil, event: probe) == .pencil && state.current == .pencil,
               "standalone leave removes only the temporary matching device")
        try proximity(42, entering: true, eraser: true, mirrored: true)
        expect(monitor.effectiveTool(selected: .pencil, event: probe) == .eraser,
               "mouse-proximity subtype independently enters Eraser after the standalone state cleared")
        expect(try session.copyPixels(actualImage, merged: true).pixels == initialPixels
               && session.undoInfo(actualImage) == initialHistory,
               "both proximity representations add no pixels, stroke or Undo")
        var eraser = EngineSession.Brush()
        eraser.tool = .eraser; eraser.size = 9; eraser.opacity = 1
        eraser.pressureSize = false; eraser.hardness = 1
        state.foreground = .black; state.update(.eraser) { $0 = eraser }
        let referenceStroke = try session.beginStroke(image: referenceImage, drawable: referenceLayer,
            brush: eraser, first: .init(x: 12, y: 16, pressure: 1, timeMilliseconds: 10_000))
        try session.continueStroke(referenceStroke, points: [
            .init(x: 36, y: 16, pressure: 1, timeMilliseconds: 10_060),
            .init(x: 52, y: 16, pressure: 1, timeMilliseconds: 10_100)])
        try session.endStroke(referenceStroke)
        let expectedPixels = try session.copyPixels(referenceImage, merged: true).pixels
        let expectedRaw = try session.copyPixels(referenceImage, merged: false).pixels
        expect(expectedPixels != initialPixels && pixel(session, referenceImage, x: 36, y: 16) == [255, 255, 255, 255]
               && pixel(session, referenceImage, x: 36, y: 40) == [220, 30, 50, 255],
               "the separate literal native eraser oracle changes the alpha layer and leaves red controls")
        canvas.mouseDown(with: probe)
        expect(doc.strokeIsActive && state.current == .pencil, "matching hardware eraser accepts paint without changing tool selection")
        state.select(.text) // Explicit choice while the accepted eraser owns the drag.
        state.update(.eraser) { $0.size = 31; $0.opacity = 0.25 }
        try proximity(42, entering: true, eraser: false, mirrored: true)
        try proximity(42, entering: false, eraser: false, mirrored: false)
        canvas.mouseDragged(with: try point(.leftMouseDragged, CGPoint(x: 36, y: 16), 10.06, device: 42))
        canvas.mouseUp(with: try point(.leftMouseUp, CGPoint(x: 52, y: 16), 10.1, device: 42))
        try drain()
        expect(!doc.strokeIsActive && state.current == .text,
               "flip/leave and a later explicit tool choice preserve the captured eraser until release")
        expect(try session.copyPixels(actualImage, merged: true).pixels == expectedPixels
               && session.copyPixels(actualImage, merged: false).pixels == expectedRaw,
               "all merged and raw pixels match the independently configured native eraser")
        expect(try session.undoInfo(actualImage).undoCount == initialHistory.undoCount + 1,
               "the temporary eraser is exactly one native Undo")
        doc.undo(); try drain()
        expect(try session.copyPixels(actualImage, merged: true).pixels == initialPixels
               && session.undoInfo(actualImage).undoCount == initialHistory.undoCount, "Undo restores pre-eraser pixels/history")
        doc.redo(); try drain()
        expect(try session.copyPixels(actualImage, merged: true).pixels == expectedPixels
               && session.undoInfo(actualImage).undoCount == initialHistory.undoCount + 1, "Redo restores exact erased pixels/history")
        try proximity(42, entering: true, eraser: true, mirrored: false)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        controller.window?.contentView?.addSubview(field)
        controller.window?.makeFirstResponder(field)
        try require(field.currentEditor() != nil, "field editor did not acquire actual focus")
        guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 20,
            windowNumber: controller.window!.windowNumber, context: nil, characters: "b", charactersIgnoringModifiers: "b",
            isARepeat: false, keyCode: 11) else { throw NSError(domain: "TabletEraserFixture", code: 8) }
        NSApp.sendEvent(key)
        expect(field.currentEditor()?.string == "b" && state.current == .text,
               "active eraser proximity does not replace text selection or steal ordinary field typing")
        controller.window?.endEditing(for: nil); field.removeFromSuperview()
        controller.window?.makeFirstResponder(canvas)
        controller.toggleSnapToCanvas(nil)
        let beforePriority = try session.undoInfo(actualImage)
        canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 21,
            windowNumber: controller.window!.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49)!)
        let commandPoint = try point(.leftMouseDown, CGPoint(x: 70, y: 40), 21.01, device: 42, flags: .command)
        canvas.mouseDown(with: commandPoint)
        expect(!doc.strokeIsActive && canvas.tools.moveSnap == nil, "held Space beats Command and hardware eraser")
        canvas.mouseUp(with: try point(.leftMouseUp, CGPoint(x: 70, y: 40), 21.02, device: 42, flags: .command))
        canvas.keyUp(with: NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 21.03,
            windowNumber: controller.window!.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49)!)
        canvas.mouseDown(with: commandPoint)
        expect(!doc.strokeIsActive && canvas.tools.moveSnap != nil, "Command beats hardware eraser and captures Move")
        canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 21.04,
            windowNumber: controller.window!.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!)
        canvas.mouseUp(with: try point(.leftMouseUp, CGPoint(x: 70, y: 40), 21.05, device: 42))
        canvas.mouseDown(with: try point(.leftMouseDown, CGPoint(x: 70, y: 40), 22, device: 42, flags: .option))
        expect(!doc.strokeIsActive && state.current == .text, "Option retains paint color sampling without global tool replacement")
        canvas.mouseUp(with: try point(.leftMouseUp, CGPoint(x: 70, y: 40), 22.01, device: 42, flags: .option))
        try drain()
        expect(try session.copyPixels(actualImage, merged: true).pixels == expectedPixels
               && session.undoInfo(actualImage) == beforePriority, "Space/Command/Option priority probes add no pixels or history")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        expect(monitor.effectiveTool(selected: .text, event: probe) == .text && state.current == .text,
               "synthetic app deactivation clears temporary devices and preserves the explicit tool")
        complete = true
    }
}
