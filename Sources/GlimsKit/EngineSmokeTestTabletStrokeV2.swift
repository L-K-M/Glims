import AppKit
import CoreGraphics
import Darwin
import IOKit.hidsystem

private struct TabletV2Delivery: Decodable {
    let sequence: Int
    let kind: String
    let image, drawable: Int32
    let time: UInt32
    let x, y, pressure, xtilt, ytilt, rotation, wheel: Double
    let distance, slider, velocity, direction, xscale, yscale, angle: Double
    let reflect: Bool
}

@MainActor
extension EngineSmokeTest {
    /// First bounded CGEvent admission and native delivery baseline. The
    /// private adapter traces real Core calls, never a production test API.
    static func exerciseTabletStrokeV2(_ session: EngineSession, documents: DocumentList) throws {
        struct Scene { let image, layer: Int32 }
        struct Pixels: Equatable { let raw, merged: Data }
        let state = ToolState.shared
        let oldTool = state.current, oldColor = state.foreground
        let oldPencil = state.brush(for: .pencil), oldEraser = state.brush(for: .eraser)
        let oldCoalescing = NSEvent.isMouseCoalescingEnabled
        var loose: [Int32] = [], owned: [ImageDocument] = [], owners: [DocumentWindowController] = []
        var count = 0, complete = false
        func expect(_ value: Bool, _ message: String) {
            count += 1; check(value, "tablet V2 input: \(message)")
        }
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "TabletV2Fixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(20)
            repeat {
                if condition() { return true }
                EngineSmokeTestHost.pumpEvents()
            } while Date() < end
            return false
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        func drain(_ doc: ImageDocument) throws {
            try require(wait { doc.pendingWork == 0 && !EngineActivity.shared.isBusy }, "Accepted native work did not drain")
        }
        defer {
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            owned.forEach { $0.endStroke() }
            owned.forEach { try? drain($0) }
            var stopped = true
            for owner in owners {
                owner.window?.orderOut(nil)
                var ready = false
                owner.canvas.stopRendering { ready = true }
                if !wait({ ready }) { stopped = false }
                owner.window?.close()
            }
            expect(stopped && wait { owned.allSatisfy { $0.pendingWork == 0 && gone($0.image) } },
                   "owned windows, renderers, strokes and native images close before shutdown")
            loose.forEach { if !gone($0) { try? session.closeImage($0) } }
            expect(loose.allSatisfy(gone) && owners.allSatisfy {
                $0.window?.isVisible != true && $0.window?.attachedSheet == nil
            }, "reference images close and no owned window or sheet remains")
            documents.items.removeAll { candidate in owned.contains { $0 === candidate } }
            state.update(.pencil) { $0 = oldPencil }; state.update(.eraser) { $0 = oldEraser }
            state.foreground = oldColor; state.select(oldTool)
            expect(NSEvent.isMouseCoalescingEnabled == oldCoalescing, "global event coalescing is unchanged")
            expect(complete, "all admitted three-sample tablet and V1 control groups completed")
            print("     tablet-stroke-v2 checks: \(count)")
        }
        guard let path = ProcessInfo.processInfo.environment["GLIMS_TABLET_V2_TELEMETRY"], path.hasPrefix("/") else {
            expect(false, "setup requires an owned absolute GLIMS_TABLET_V2_TELEMETRY path")
            return
        }
        let traceURL = URL(fileURLWithPath: path)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        try require(fd >= 0, "Telemetry path must be a new owned file")
        close(fd)
        func rows() throws -> [TabletV2Delivery] {
            let data = try Data(contentsOf: traceURL)
            try require(data.count <= 1_048_576, "Native telemetry exceeded its byte bound")
            let lines = data.split(separator: 10)
            try require(lines.count <= 1024 && (data.isEmpty || data.last == 10), "Native telemetry is incomplete or exceeded its row bound")
            let decoded = try lines.map { try JSONDecoder().decode(TabletV2Delivery.self, from: Data($0)) }
            try require(decoded.enumerated().allSatisfy { $0.element.sequence == $0.offset + 1 }, "Native telemetry sequence is incomplete")
            return decoded
        }
        func pixels(_ image: Int32) throws -> Pixels {
            try .init(raw: session.copyPixels(image, merged: false).pixels,
                      merged: session.copyPixels(image, merged: true).pixels)
        }
        let rgba = ClipboardImage(width: 96, height: 64,
            pixels: Data((0..<(96 * 64)).flatMap { _ in [UInt8(220), 30, 50, 255] }), origin: .zero)
        func scene() throws -> Scene {
            let image = try session.newImage(width: 96, height: 64); loose.append(image)
            let layer = try session.pastePixels(image, pixels: rgba, at: .zero)
            try session.selectLayer(layer, image: image)
            return .init(image: image, layer: layer)
        }
        func document(_ scene: Scene, name: String) throws -> ImageDocument {
            let doc = try ImageDocument(session: session, image: scene.image, name: name)
            loose.removeAll { $0 == scene.image }; owned.append(doc); documents.items.append(doc)
            let owner = DocumentWindowController(document: doc); owners.append(owner)
            owner.showWindow(nil); owner.zoom(to: 100)
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            try drain(doc)
            return doc
        }
        let source = try scene(), other = try scene(), eraserReference = try scene(), mouseReference = try scene()
        let a = try document(source, name: "Tablet V2 A"), b = try document(other, name: "Tablet V2 B")
        let ownerA = owners[0], ownerB = owners[1], canvas = ownerA.canvas
        var errors: [String] = []; a.onError = { errors.append($0) }
        let before = try pixels(source.image), otherBefore = try pixels(other.image)
        let undoBefore = try session.undoInfo(source.image), otherUndo = try session.undoInfo(other.image)
        var eraser = EngineSession.Brush(); eraser.tool = .eraser
        eraser.size = 9; eraser.opacity = 1; eraser.pressureSize = false; eraser.hardness = 1
        var pencil = eraser; pencil.tool = .pencil
        state.foreground = .black
        state.update(.eraser) { $0 = eraser }; state.update(.pencil) { $0 = pencil }; state.select(.pencil)
        let eventTimes = [10.0, 10.0625, 10.125]
        let positions = [CGPoint(x: 12, y: 16), CGPoint(x: 36, y: 16), CGPoint(x: 52, y: 16)]
        let pressures = [0.5, 0.75, 1.0]
        func reference(_ scene: Scene, brush: EngineSession.Brush, tablet: Bool) throws -> Pixels {
            var stroke: Int32?
            defer { if let stroke { try? session.endStroke(stroke) } }
            stroke = try session.beginStroke(image: scene.image, drawable: scene.layer, brush: brush,
                first: .init(x: 12, y: 16, pressure: tablet ? 0.5 : 1,
                             xTilt: tablet ? 0.25 : 0, yTilt: tablet ? 0.5 : 0, timeMilliseconds: 10_000))
            try session.continueStroke(stroke!, points: [
                .init(x: 36, y: 16, pressure: tablet ? 0.75 : 1, xTilt: tablet ? 0.25 : 0,
                      yTilt: tablet ? 0.5 : 0, timeMilliseconds: 10_062),
                .init(x: 52, y: 16, pressure: 1, xTilt: tablet ? 0.25 : 0,
                      yTilt: tablet ? 0.5 : 0, timeMilliseconds: 10_125)])
            try session.endStroke(stroke!); stroke = nil
            return try pixels(scene.image)
        }
        func baseDelivery(_ entries: [TabletV2Delivery], scene: Scene, tablet: Bool) -> Bool {
            guard entries.count == 6, entries.map(\.kind) == ["start", "init", "motion", "interpolate", "interpolate", "finish"],
                  entries.map(\.time) == [0, 10_000, 10_000, 10_062, 10_125, 0],
                  entries.allSatisfy({ $0.image == scene.image && $0.drawable == scene.layer }) else { return false }
            return entries.prefix(5).enumerated().allSatisfy { offset, row in
                let i = offset < 3 ? 0 : offset - 2
                return abs(row.x - positions[i].x) < 0.001 && abs(row.y - positions[i].y) < 0.001
                    && abs(row.pressure - (tablet ? pressures[i] : 1)) < 0.001
                    && abs(row.xtilt - (tablet ? 0.25 : 0)) < 0.001 && abs(row.ytilt - (tablet ? 0.5 : 0)) < 0.001
                    && row.distance == 0 && row.slider == 0 && row.velocity == 0 && row.direction == 0
                    && row.xscale == 1 && row.yscale == 1 && row.angle == 0 && !row.reflect
            }
        }
        func absent(_ entries: [TabletV2Delivery]) -> Bool {
            entries.prefix(5).allSatisfy { $0.rotation == 0 && $0.wheel == 0.5 }
        }
        let erased = try reference(eraserReference, brush: eraser, tablet: true)
        let mousePainted = try reference(mouseReference, brush: pencil, tablet: false)
        let referenceRows = try rows()
        let actualReference = referenceRows.filter { $0.image == eraserReference.image }
        let actualMouseReference = referenceRows.filter { $0.image == mouseReference.image }
        let traceAdmitted = referenceRows.count == 12 && baseDelivery(actualReference, scene: eraserReference, tablet: true)
            && baseDelivery(actualMouseReference, scene: mouseReference, tablet: false)
            && absent(actualReference) && absent(actualMouseReference)
        expect(traceAdmitted, "private forwarding adapter records real literal V1 coordinates, IDs and ordered times")
        try require(traceAdmitted, "Private native telemetry is missing; optional-coordinate behavior is NOT RUN")
        expect(try erased != before && mousePainted != before
            && session.undoInfo(eraserReference.image).undoCount == undoBefore.undoCount + 1,
               "independent native Eraser and Pencil references change exact pixels and one Undo")
        NSApp.activate(ignoringOtherApps: true)
        func front(_ owner: DocumentWindowController) throws {
            owner.window?.makeKeyAndOrderFront(nil); owner.window?.makeMain()
            try require(wait { NSApp.isActive && NSApp.keyWindow === owner.window && NSApp.mainWindow === owner.window },
                        "The actual owned document did not become main and key")
        }
        func point(_ index: Int, device: UInt?) throws -> NSEvent {
            let type: NSEvent.EventType = [.leftMouseDown, .leftMouseDragged, .leftMouseUp][index]
            guard let window = ownerA.window,
                  let template = NSEvent.mouseEvent(with: type,
                    location: canvas.convert(CGPoint(x: positions[index].x * canvas.scale,
                                                     y: positions[index].y * canvas.scale), to: nil),
                    modifierFlags: [], timestamp: eventTimes[index], windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw NSError(domain: "TabletV2Fixture", code: 2)
            }
            guard let device else { return template }
            guard let cg = template.cgEvent else { throw NSError(domain: "TabletV2Fixture", code: 3) }
            cg.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
            cg.setIntegerValueField(.tabletEventDeviceID, value: Int64(device))
            cg.setDoubleValueField(.mouseEventPressure, value: pressures[index])
            cg.setDoubleValueField(.tabletEventPointPressure, value: pressures[index])
            cg.setDoubleValueField(.tabletEventTiltX, value: 0.25); cg.setDoubleValueField(.tabletEventTiltY, value: 0.5)
            cg.setDoubleValueField(.tabletEventRotation, value: [90.0, 180.0, 270.0][index])
            cg.setDoubleValueField(.tabletEventTangentialPressure, value: [1.0, 0.5, 0.0][index])
            cg.timestamp = UInt64(eventTimes[index] * 1_000_000_000)
            guard let event = NSEvent(cgEvent: cg) else { throw NSError(domain: "TabletV2Fixture", code: 4) }
            let mapped = canvas.imagePoint(for: event)
            let admitted = event.type == type && event.subtype == .tabletPoint && UInt(exactly: event.deviceID) == device
                && abs(mapped.x - positions[index].x) < 0.001 && abs(mapped.y - positions[index].y) < 0.001
                && abs(Double(event.pressure) - pressures[index]) < 0.001
                && abs(Double(event.tilt.x) - 0.25) < 0.001 && abs(Double(event.tilt.y) - 0.5) < 0.001
                && abs(Double(event.rotation) - [90, 180, 270][index]) < 0.001
                && abs(Double(event.tangentialPressure) - [1, 0.5, 0][index]) < 0.001
            try require(admitted, "CGEvent to NSEvent tablet values were not admitted; behavioral axis checks are NOT RUN")
            print("OBS tablet input index=\(index) device=\(event.deviceID) pressure=\(event.pressure) tilt=\(event.tilt) rotation=\(event.rotation) tangent=\(event.tangentialPressure) timestamp=\(event.timestamp)")
            return event
        }
        let monitor = TabletEraserProximity.shared
        let optionalBits = UInt(NX_TABLET_CAPABILITY_ROTATIONMASK) | UInt(NX_TABLET_CAPABILITY_TANGENTIALPRESSUREMASK)
        func proximity(_ device: UInt, capabilities: UInt, probe: NSEvent) throws {
            guard let cg = CGEvent(source: nil) else { throw NSError(domain: "TabletV2Fixture", code: 5) }
            cg.type = .tabletProximity
            cg.setIntegerValueField(.tabletProximityEventDeviceID, value: Int64(device))
            cg.setIntegerValueField(.tabletProximityEventPointerType, value: Int64(NSEvent.PointingDeviceType.eraser.rawValue))
            cg.setIntegerValueField(.tabletProximityEventCapabilityMask, value: Int64(capabilities))
            cg.setIntegerValueField(.tabletProximityEventEnterProximity, value: 1)
            guard let event = NSEvent(cgEvent: cg) else { throw NSError(domain: "TabletV2Fixture", code: 6) }
            let admitted = event.type == .tabletProximity && UInt(exactly: event.deviceID) == device
                && event.isEnteringProximity && event.pointingDeviceType == .eraser
                && UInt(event.capabilityMask) & optionalBits == capabilities
            try require(admitted, "CGEvent to NSEvent proximity/capability admission failed")
            NSApp.postEvent(event, atStart: false)
            let observed = wait { monitor.effectiveTool(selected: .pencil, event: probe) == .eraser }
            expect(admitted && observed, "real proximity monitor and NSEvent capability readback admit device \(device)")
            try require(observed, "Actual passive proximity monitor did not receive the owned device")
        }
        let matched = try (0..<3).map { try point($0, device: 42) }
        try front(ownerA); try proximity(42, capabilities: optionalBits, probe: matched[0])
        expect(try rows().count == 12 && pixels(source.image) == before,
               "proximity carries no paint samples or duplicate native stroke")
        let firstSequence = try rows().last!.sequence
        canvas.mouseDown(with: matched[0])
        expect(a.strokeIsActive && state.current == .pencil, "matched hardware Eraser accepts one captured gesture without replacing the selected tool")
        try front(ownerB)
        canvas.mouseDragged(with: matched[1]); canvas.mouseUp(with: matched[2]); try drain(a)
        let first = try rows().filter { $0.sequence > firstSequence && $0.image == source.image }
        expect(baseDelivery(first, scene: source, tablet: true), "A while B is main delivers exactly one ordered native three-sample gesture to A's image/layer")
        let rotations = [0.25, 0.25, 0.25, 0.5, 0.75], wheels = [1.0, 1.0, 1.0, 0.75, 0.5]
        expect(first.count == 6 && zip(first.prefix(5), zip(rotations, wheels)).allSatisfy {
            abs($0.0.rotation - $0.1.0) < 0.001 && abs($0.0.wheel - $0.1.1) < 0.001
        }, "matching optional tablet axes reach actual Core with literal turns and signed-tangent wheel mapping")
        expect(try pixels(source.image) == erased && session.undoInfo(source.image).undoCount == undoBefore.undoCount + 1,
               "matched stroke raw/composite pixels and one Undo equal independent native Eraser")
        expect(try pixels(other.image) == otherBefore && session.undoInfo(other.image) == otherUndo
            && !b.strokeIsActive && NSApp.mainWindow === ownerB.window,
               "front document B's pixels/history and focus remain independent")
        a.undo(); try drain(a)
        expect(try pixels(source.image) == before, "Undo restores A's exact initial pixels")

        for tablet in [false, true] {
            let events = try (0..<3).map { try point($0, device: tablet ? 43 : nil) }
            try front(ownerA)
            if tablet { try proximity(43, capabilities: 0, probe: events[0]) }
            let fence = try rows().last!.sequence
            canvas.mouseDown(with: events[0]); canvas.mouseDragged(with: events[1]); canvas.mouseUp(with: events[2]); try drain(a)
            let control = try rows().filter { $0.sequence > fence && $0.image == source.image }
            expect(baseDelivery(control, scene: source, tablet: tablet) && absent(control),
                   tablet ? "matching tablet with no optional capabilities retains V1 base axes and neutral optional coordinates"
                          : "ordinary mouse retains V1 base defaults and neutral optional coordinates")
            expect(try pixels(source.image) == (tablet ? erased : mousePainted)
                && session.undoInfo(source.image).undoCount == undoBefore.undoCount + 1,
                   tablet ? "no-capability tablet matches direct V1 Eraser pixels and one Undo"
                          : "mouse matches direct V1 Pencil pixels and one Undo")
            a.undo(); try drain(a)
            expect(try pixels(source.image) == before && !a.strokeIsActive, "control End occurs once and Undo restores the baseline")
        }
        expect(try errors.isEmpty && rows().count == 30 && pixels(other.image) == otherBefore,
               "all native calls are accounted for without duplicate strokes or other-document mutation")
        print("OBS tablet V2 native trace retained at \(traceURL.path)")
        complete = true
    }
}
